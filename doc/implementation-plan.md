# Implementation plan — per-platform schemes, austere surface

*Point-in-time implementation plan, kept for the record. The as-built system
has moved past it in places — where this file disagrees with
[design.md](design.md) or the code, the code wins.*

Executes the [SDK guide's "How your secrets are protected"](sdk.md#how-your-secrets-are-protected)
table. Governing rules:
**one clear way to do things** (a knob must justify its existence or die),
**maximum reuse** (a new platform = one new binding *or* one new key source,
never a new stack), and **small code = small attack surface**.

## 0. The one sequencing constraint (why the macOS probe is in v1)

If v1 shipped "always file" on macOS and the DP-keychain probe came later, an
*entitled* app would store in the file today and silently flip to the DP
keychain on upgrade — the store-location split-brain we've spent this design
avoiding. Both probe branches already exist in the tree
(`AppleKeychainApi.dataProtection()` with −34018 mapping; `KeystoreBackend`), so
the probe ships **in v1** and every binary lands in its final location from
day one. The entitled branch is validated end-to-end via the `example_flutter/`
harness ([tool/dp_keychain_verification.md](../tool/dp_keychain_verification.md),
local-only — needs signing) — CI covers the −34018 path, which is also the only
path CI can take.

## 1. Target public API (the whole thing)

```dart
final store = SecretStorage(appId: 'com.example.myapp'); // the one way
// + read / readString / write / writeString / containsKey / delete /
//   readAll / deleteAll / describe()
SecretStorage.withBackend(fakeBackend);                  // test hatch only
```

Exported symbols after this plan: `SecretStorage`, the verbs above, the typed
errors, `BackendInfo`/`BackendCapabilities`/`SecretBackend` (so consumers can
fake the store in their own tests), and nothing else.
Headless is **out of scope** (owner call 2026-07-10) — design preserved in
[headless-implementation-plan.md](headless-implementation-plan.md).

**Knobs eliminated** (all exist today; all die in phase 1):

| Knob | Replaced by |
|---|---|
| `service:` | `appId:` (rename; also derives the file path + keystore identity) |
| `api:` override / `AppleKeychainApi.dataProtection()` as public opt-in | the automatic DP probe (§2) |
| `SecretStorage.encryptedFile(path:, keySource:, contextSalt:)` | internal composition; path derived from `appId`; `contextSalt` deleted |
| `AppleKeychainApi(nonInteractive:)` | hardcoded ON (`kSecUseAuthenticationUIFail` always): a locked login keychain is abnormal (it auto-unlocks at login), and a typed `KeystoreLocked` beats a GUI prompt that hangs over SSH. One behavior, no knob. |
| exported `SystemKeySource`, `TpmKeySource`, `TpmKeyBinding`, `KeySource`, `platformKeystore`, `AppleKeychainApi`, `SecretToolApi`, `KeystoreApi`, `KeystoreProbe`, `SecureFileSystem`, `ProcessRunner` family | unexported. All stay in-tree and tested. (`TpmKeySource`/`TpmKeyBinding` were later removed outright with headless's descoping — design.md §12.) |

## 2. The resolver (new code, ~100 lines + tests)

`SecretStorage(appId:)` picks the scheme:

```
macOS   → probe DP keychain once (cached per process):
            write+delete a probe item via SecItem
            −34018            → EncryptedFileBackend + key in login Keychain   (S3)
            success           → KeystoreBackend over the DP keychain (native
                                items; hardware level unreported)
            any other error   → throw (typed, loud — misconfigured entitlement)
Linux   → EncryptedFileBackend + key in Secret Service                          (S3)
else    → throw KeystoreUnreachable with guidance (Windows is planned)
```

There is no dedicated headless resolver branch or reliable headless detector.
An unavailable desktop credential service surfaces a typed backend error, but
that is an availability result rather than a promise to classify every
headless environment.

Probe determinism: entitlements are baked into the code signature, so the
probe is stable per binary — the store location can only change when the
developer re-signs with different entitlements (documented: one-time re-auth;
we never auto-migrate).

## 3. `appId` → derived locations (traversal-safe by construction)

- **Grammar (tightened):** `[A-Za-z0-9._-]{1,120}` — **no `/`** (unlike the
  key grammar), must contain at least one alphanumeric (rejects `.` / `..`).
  One validated path segment ⇒ traversal impossible by construction, not by
  filtering. Tests assert `..`, `../x`, `/abs`, `a/b` all throw.
- **Container path:** macOS `~/Library/Application Support/<appId>/secrets.enc`;
  Linux `${XDG_DATA_HOME:-~/.local/share}/<appId>/secrets.enc`. Parent dir
  created `0700` by the existing shim; missing `HOME` → typed error.
- **Keystore identity:** service = `<appId>`, account = `store-key` (existing
  `SystemKeySource` shape). DP-keychain native items: service = `<appId>`,
  account = the user's key.

## 4. `BackendInfo.level` (as built)

`SecurityLevel { hardwareBacked, softwareBacked, loginBound }` is optional.
Authenticated-file paths backed by a login credential report `loginBound`.
Android inspects the actual KEK provider and reports hardware only for TEE or
StrongBox. Apple native items leave the value null: the applied Data Protection
Keychain policy is known, but Keybay has no per-item hardware attestation and
does not infer one from unrelated device capabilities.

## 5. Reuse map (what each future platform costs)

Every scheme is a composition of existing parts; a platform adds exactly one
part:

| Platform | Backend (exists) | Key source / binding | New code |
|---|---|---|---|
| macOS CLI | EncryptedFileBackend | SystemKeySource + AppleKeychainApi (login) | — (v1 wiring) |
| macOS entitled | KeystoreBackend | AppleKeychainApi.dataProtection | — (v1 wiring + probe) |
| Linux desktop | EncryptedFileBackend | SystemKeySource + SecretToolApi | — (v1 wiring) |
| headless | — out of scope; prototype removed (design.md §12) | — | — |
| Windows | EncryptedFileBackend | SystemKeySource + **WinCredApi** | one FFI binding |
| iOS | KeystoreBackend | **iOS SecItem binding** (≈ keychain.dart, DP always-on) | one binding + decisions below |
| Android | EncryptedFileBackend | **AndroidKeystoreKeySource** (pure-FFI JNI) | one key source + backup rules |

## 6. Phases

**Phase 1 — v1 (now):** resolver + probe; `appId` grammar/derivation +
traversal tests; knob elimination + export trim; `SecurityLevel` on
`BackendInfo`; update example and SDK guide platform claims (macOS-entitled →
shipped, manual-verified), architecture.md alignment (still says "always file" — fix to
the three-tier model), design doc §4, CHANGELOG (breaking: default scheme
changes from direct items to file — pre-1.0, no migration, re-provision).
Verify: full unit tier + macOS integration (real round-trip via `appId`; probe
−34018 path) + `tool/test_linux.sh` (real gnome-keyring) + the entitled DP leg
via the `example_flutter/` harness.

> **Priority (owner call, 2026-07-09): mobile before servers.** iOS and
> Android are the platforms that unlock one audited store across the desktop
> CLI and Flutter apps and serve the most users; Windows
> follows (headless has since been descoped entirely). Order: **iOS →
> Android → Windows.** Both mobile
> backends are buildable *with real verification* on the current dev machine
> (Xcode 26.6 + iPhone simulators; Android SDK + emulator; Flutter 3.44.4).

**Phase 2 — iOS.** Both native-item rows share one truth: on iOS the DP keychain is the
*only* keychain (`kSecUseDataProtectionKeychain` is implied), so there is **no
probe** — the resolver branch is unconditional native items. The scheme is
reported; a hardware level is not.
Work:
1. **Binding variant**: today's `AppleKeychainApi` opens Security.framework by
   absolute macOS path; on iOS the symbols come from the app process
   (`DynamicLibrary.process()` — verify on the simulator). Same SecItem code
   otherwise; this is a constructor-level difference, not a new binding.
2. **Recorded decisions land here**: accessibility
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on every add (constant,
   no knob — device-bound, no iCloud/backup escrow, readable by background
   work after first unlock); `synchronizable=false` (carried over);
   no first-run uninstall sentinel: Keychain items commonly persist across
   uninstall, but Apple does not guarantee either persistence or deletion, so
   applications must tolerate both; document the value envelope.
3. **Test harness (new infra)**: a minimal Flutter host app under
   `example_flutter/` + `integration_test/` running the same round-trip suite
   as the macOS integration tier, executed on the iPhone simulator
   (`flutter test integration_test -d <sim>`). This also becomes the living
   proof of the "runs inside Flutter apps" claim. The simulator validates the
   genuine API path and item policy; it makes no physical-hardware claim.
   **No entitlement matrix on iOS**: there is no entitled/unentitled fork
   there (every iOS app has an implicit default access group; Keychain
   Sharing only matters for cross-app sharing) — one project, one
   unconditional path.
4. **Bonus the harness unlocks — the macOS DP matrix.** The same Flutter app
   builds for macOS desktop, giving the two-config test the CLI tier can't:
   (a) **Keychain Sharing enabled + development-signed** → resolver must pick
   native DP items with no inferred hardware level — turning the DP **success** branch from
   a manual checklist (tool/dp_keychain_verification.md) into a scripted,
   repeatable local test; (b) **entitlement removed** → encrypted file +
   login-Keychain key, `loginBound` (−34018 inside a real app bundle). Local
   only (signing needs a team identity CI lacks); CI keeps the −34018 CLI
   branch it already covers.
   *Status (2026-07-09):* **both legs validated.** Leg (b) green; leg (a) — the
   DP **success** branch — validated end-to-end after accepting the Apple
   Developer PLA (the one-time blocker): the entitled overlay (team + identity +
   keychain-access-groups) signed the bundle with `application-identifier` +
   `keychain-access-groups`, `-allowProvisioningUpdates` created the profile,
   and `flutter test … --dart-define=EXPECT_SCHEME=native` asserted
   `nativeItems`, a null level, and a full DP-keychain round-trip. The overlay
   is reverted out of the committed default (no personal team ID in the repo);
   re-run via tool/dp_keychain_verification.md.
5. Resolver: `Platform.isIOS → KeystoreBackend(service: appId, api: iOS
   binding)`. Path derivation is not needed (no file), and level remains null.

**Phase 3 — Android.** The file scheme with a Keystore-wrapped key — the one
platform where B is forced (Keystore stores keys, not blobs).

> **Architecture (2026-07-10, supersedes the jnigen plan and the interim
> "federation is forced" analysis): pure `dart:ffi` JNI in core — no
> `package:jni`, no companion package, zero new dependencies.**
> `package:jni` cannot be a core dependency: every version requires the
> Flutter SDK to resolve (proven in Flutter-less Docker), the constraint is
> *forced* on it by pub's publish validation for plugin sections (proven via
> `dart pub publish --dry-run`), and its Android bootstrap rides Flutter's
> plugin registrant. The escape: Android officially exports
> **`JNI_GetCreatedJavaVMs` from `libnativehelper` at API 31+**
> (android/ndk#1320), so a dlopen'd pure-FFI caller can discover the VM with
> no `JNI_OnLoad`, no Java, no plugin. Everything Keystore needs is a
> **boot-classpath framework class**, so the app-classloader problem that
> blocks the Dart team's own de-Flutter migration of package:jni
> (dart-lang/native#2997, blocked on #1350 Java-bytecode assets) does not
> apply. **Proven end-to-end** on an API 33 emulator by a standalone probe
> (2026-07-10; since removed — one JNI implementation only): dlopen →
> `JNI_GetCreatedJavaVMs` → attach → `FindClass(java/security/KeyStore)` →
> `KeyStore.getInstance("AndroidKeyStore")` → non-null. The production shim
> now proves the same chain on every emulator run. **Floor: API 31**
> (Android 12); below it the resolver throws typed guidance — fail-closed,
> no plugin fallback. Off-ramp: when dart-lang/native#2997 lands, the shim
> can be re-evaluated against official jni behind the same internal seam.

Work:
1. **`lib/src/ffi/jni.dart`** — hand-rolled minimal JNI over `dart:ffi`
   (~24 env functions: classes/methods/calls A-variants, strings, byte
   arrays, string arrays, local frames, exception→typed-error mapping with
   attach-check per use). Same austerity class as the CoreFoundation
   binding; framework classes only, no Java shipped.
2. **`AndroidKeystoreKeySource`** over that shim: AES-256-GCM KEK in
   AndroidKeyStore (`setUserAuthenticationRequired(false)` — the best-case
   reliability profile; StrongBox try-then-fallback via
   `StrongBoxUnavailableException` detection), wrap/unwrap our 32-byte store
   key, wrapped blob (versioned, pure-codec, unit-tested) stored beside the
   container, **write-time self-test** (wrap→unwrap→compare before trusting
   — Tink's lesson; fail closed, no silent software fallback).
3. **Container path without Context**: `System.getProperty("java.io.tmpdir")`
   (public API, no hidden-API risk) → the app cache dir → sibling
   `<dataDir>/files` per the stable ApplicationInfo layout; pure derivation
   + validation in `app_paths.dart`, unit-tested.
4. **The ecosystem lessons land here** (design.md §9): ship
   **backup-exclusion documentation + manifest snippets** (we are not a
   plugin, so rules are documented, not auto-injected — say so loudly);
   typed **`KeyInvalidated`** error for the key-loss matrix (blob present
   but KEK gone/unusable — restore-to-new-device, OEM eviction, blob
   corruption); diagnostics inspect `KeyInfo.getSecurityLevel()` and report
   `hardwareBacked` only for TEE/StrongBox, otherwise `softwareBacked`.
5. **Test harness**: same Flutter host app, Android emulator leg (local-first
   like the DP leg; CI emulator via android-emulator-runner is a recorded
   follow-up). The standalone JNI probe that first proved the mechanism was
   deleted once the production shim shipped — carrying a second, duplicate
   JNI implementation fails the austerity bar; the harness suite exercises
   the full chain against the real Keystore on every run.

**Phase 4 — headless: DROPPED (owner call, 2026-07-10).** Out of scope for
now. The TpmKeySource prototype was built, validated against real
`systemd-creds`, and removed from the tree (unreachable code = unjustified
surface). Design preserved in
[headless-implementation-plan.md](headless-implementation-plan.md);
implementation in git history.

**Phase 5 — Windows (next):** `WinCredApi` FFI (key custody only — 32-byte
value, far under wincred's 2560-byte cap) + resolver row + CI runner.

Non-goals (unchanged): BYO/KMS key sources, per-item biometric policies,
rollback counters, web.
