# secret_store — ecosystem comparison & benchmark

How `secret_store` compares to best-in-class secret storage across the
ecosystems it borrows from: its own peer class (Rust/Python/Go keyring
libraries, credential helpers), the Dart/Flutter incumbent
(`flutter_secure_storage`), the React Native / Expo stack, and native
iOS/Android practice. Based on a July 2026 research pass over primary sources
(library source at pinned versions, platform docs, issue trackers, advisory
databases). This is a living benchmark, not a one-time audit — the "gaps" and
"flags" sections are the actionable output.

**One-line verdict.** On architecture and the file-container path,
`secret_store` is at or ahead of every peer surveyed — it is the *only* one
that combines authenticated encryption, key commitment, a rollback-binding
field, atomic writes, `fsync`, and advisory locking, and its fail-closed +
never-leak-values discipline beats the mainstream tools. Where it is behind is
never the crypto or the robustness; it is **API surface** (no accessibility
tiers, no hardware-backing reporting, no typed key-invalidation error, no
rekey API) and one **capability** (no shipped headless hardware-bound key
source yet). None of the gaps are architectural; all are additive.

---

## 1. Where we stand, by dimension

Ahead / Equal / Behind is relative to the *best* peer on that dimension.

| Dimension | Standing | Notes |
|---|---|---|
| AEAD / integrity | **Ahead** | XChaCha20-Poly1305 **+ key commitment**. RN-keychain shipped AES-CBC-*without*-MAC as its default until v9.2.0 (2024); MMKV is AES-CFB + CRC32 (no auth); 99designs uses JWE (fine, opaque). Nobody mainstream is key-committing. |
| Rollback protection | **Equal (none)** | We're at parity with `age`/`sops`/99designs — nobody in the peer class has it. A generation field was prototyped and cut (a counter bound in the AAD is only tamper-evident, not anti-rollback); real resistance needs a keystore-anchored counter, a possible v2. See Flag 4. |
| Fail-closed resolution | **Ahead** | We throw off a supported platform. `gh` and `docker` silently fall back to plaintext; `flutter_secure_storage`'s `resetOnError` (default **true**) silently wipes. Ties `git-credential-manager` (also refuses on Linux with no store). |
| Typed errors, never carrying values | **Ahead** | Full failure matrix; the "no secret in errors/logs" invariant is stronger than keyring-rs (attaches platform errors) and `zalando/go-keyring` (a failed `security` store echoes stdin). MMKV's CVE-2024-21668 was exactly a key-in-logs leak. |
| Bytes-first values | **Ahead** | Everyone else in the mobile/CLI space is String-first (`flutter_secure_storage`, expo, RN-keychain, Python/Go keyring). keyring-rs added `get_secret`/`set_secret` (bytes) — the one peer at parity. |
| File-container durability (atomic + fsync) | **Ahead** | 99designs (`WriteFile`, no fsync), `flutter_secure_storage` on Windows (non-atomic whole-file rewrite) lag; we do 0600-from-birth + atomic rename + dir-fsync. (An advisory `flock` was prototyped and cut — cross-process locking is out of scope; a container is single-writer, like most of the file-based peers.) |
| macOS ACL correctness | **Ahead of the Go libs** | Direct SecItem FFI respects Keychain ACLs. `zalando/go-keyring` shells out to `/usr/bin/security`, which their own issue #110 admits makes items "as secure as … global read permissions." Equal to keyring-rs / `flutter_secure_storage` (also native API). |
| Linux transport | **Equal** | We inherit libsecret's encrypted D-Bus session (`dh-ietf1024…`, libsecret's default) via `secret-tool`; the Go libs hard-code `plain`. Same-host, so this is defense-in-depth either way. |
| Platform breadth | **Behind** | We have macOS + Linux + portable container. `flutter_secure_storage` has 6 platforms; keyring-rs has macOS/Windows/Linux(×3). No iOS/Android/Windows/web yet (all recorded). |
| Hardware backing / biometric gating | **Behind (by design, for now)** | No Secure Enclave / StrongBox / biometric option. Correct non-goal while the backends are macOS + Linux (no UI/biometric context on a server or CLI); needed the day the iOS/Android backends land, since a Flutter app *is* a UI context. |
| Headless hardware-bound key source | **Behind** | keyring-rs ships a headless `keyutils` store today; systemd-creds+TPM2 is becoming the server standard. Our TPM `KeySource` is a follow-up. See Flag 1. |
| Accessibility / availability tiers | **Behind** | No `kSecAttrAccessible`-equivalent. Every serious iOS library (Valet, RN-keychain, expo) exposes tiers. Needed for the iOS backend. See Flag/Adopt. |
| Security-level *reporting* | **Behind** | RN-keychain's `getSecurityLevel()` and its `storage` result field tell callers what backing they actually got; we don't. See Adopt 1. |
| Migration / rekey API | **Behind** | No rotation surface yet. `flutter_secure_storage` and RN-keychain both do migrate-on-read (never downgrading). See Adopt 4. |
| Memory hygiene | **Equal to Go, behind Rust** | We zero native staging buffers, but GC-heap plaintext can't be zeroed. Rust peers have `zeroize`. Inherent to the runtime. See Flag 2. |
| Crypto supply chain | **Ahead** | Exact pin + vector firewall + implementation pinned past the swappable service locator + CI canary. Peers float their crypto deps (RN-keychain selects cipher by API level; MMKV silently truncates keys to 16 bytes). |

---

## 2. Where we are NOT airtight (honest flags)

These are the places a reviewer should push, ordered by how much they matter.

1. ~~**No headless hardware-bound key source yet.**~~ **RESOLVED (2026-07):
   `TpmKeySource` shipped.** The server story now is `TpmKeySource` —
   `systemd-creds` with TPM2 binding (AES-256-GCM, PCR-bound), fail-closed
   without a TPM — so a headless box gets hardware-bound at-rest (S1), not a
   key on disk. This was the field's direction (LINSTOR 1.33.0, RHEL9 guidance,
   2025–26; keyring-rs ships headless `keyutils`), and **no other
   cross-language keyring library wraps `systemd-creds`** — so shipping it
   leapfrogs the peer class rather than merely catching up.

2. **Memory hygiene is not airtight, and can't fully be in Dart.** We zero the
   native `malloc`/CFData staging buffers, and the Linux transport is
   bytes-only — but decrypted plaintext and the store key still live in GC-heap
   `Uint8List`s that Dart cannot zero, and a compacting GC can leave stale
   copies. This is parity with Go and behind Rust (`zeroize`). A `SecretBuffer`
   (mlock'd, zero-on-dispose native memory) for the canonical store-key copy is
   the recorded mitigation; the honest posture is "documented limitation," and
   the README says so.

3. **Rollback protection is a field, not yet a mechanism** (see Flag 4 detail
   below — split out because it's the subtlest).

4. **No rollback protection** (parity with the peer class, not a deficit unique
   to us). A generation counter was prototyped and cut: a counter bound in the
   AAD is only *tamper-evident* — an attacker who restores an older *whole*
   container restores its counter with a valid tag, and it verifies (exactly
   `age`'s gap). Real resistance needs the counter compared to a floor held
   where the attacker can't also roll it back (keystore-anchored value or TPM
   monotonic counter); that is a possible **v2**, not carried speculatively
   today.

5. **`Ambiguous`/multiple-match is undefined behavior.** On the Secret Service
   path another application can write an item with a colliding `service` +
   `account`; `secret-tool lookup` then returns *a* value and we take it.
   keyring-core models this as a typed `Ambiguous` variant. We should detect
   and surface it rather than silently returning the first match. (macOS
   `kSecMatchLimitOne` has the same latent ambiguity.) Recorded follow-up.

6. **Interop divergence is real and now documented.** Our Linux items key on
   `service` + **`account`** with **base64** values; Python/Go/Rust keyring use
   `service` + **`username`** with **plaintext**. So our items are not readable
   by those tools and vice-versa. This is a deliberate bytes-safety/no-`String`
   trade, not a bug — but it was silent, and is now stated in the design doc so
   nobody expects interop.

**Not a flag, but state it:** the macOS trust-unit caveat (any process running
the same `dart`/compiled binary reads items without a prompt; any same-user
process reads via `secret-tool`) is inherent to the platforms — Python
`keyring` #457 is the canonical write-up. Already documented in our threat
model.

---

## 3. What to adopt / adapt / reject

Synthesized across all five peer studies. "Adopt" = do it (mostly when the
relevant backend lands); "Adapt" = good idea, change the shape; "Reject" =
a peer does it, we deliberately shouldn't.

### Adopt

1. **Security-**backing** reporting in `BackendInfo`.** One enum — software /
   OS-keystore / TEE / StrongBox / Secure Enclave / TPM — mirroring
   RN-keychain's `getSecurityLevel()` and its `storage` result field, and
   `KeyInfo.getSecurityLevel()` / `SecureEnclave.isAvailable`. Security posture
   you can't observe, you can't enforce. Fits the honest-capabilities principle
   we already apply to `enumeration`.

2. **Typed `KeyInvalidated` error + a per-platform key-loss matrix.** Key
   invalidation is the ecosystem's #1 production failure: Android
   `KeyPermanentlyInvalidatedException` on lock-screen reset / biometric
   re-enrollment; keystore keys never surviving OS backup/restore (the
   data-loss "storms": `flutter_secure_storage` #43/#210/#541/#871, expo
   #23426, RN-keychain #565/#617); iOS keychain items surviving uninstall
   (needs a first-run sentinel). Document what happens to the container and to
   keystore entries across uninstall / OS restore / device migration, each
   mapped to a typed error. Slots straight into our existing taxonomy.

3. **Accessibility tier, required at construction, part of the namespace** —
   for the future iOS / DP-keychain backend. This is Square **Valet's**
   most-copied decision (same identifier + different accessibility = disjoint
   stores). Pin it per-store, **never per-call**: `flutter_secure_storage`'s
   per-call accessibility doubles as a keychain *search filter* and silently
   orphans items (#1164). We already pin config at construction, so we're
   positioned for this.

4. **A `rekey()` / migration story, using the crash-resistant protocol.** No
   rotation surface yet. When the format next changes (a v2 — e.g. rollback
   protection), adopt `flutter_secure_storage`'s v10 playbook — backup copy +
   per-key progress markers + commit-before-advance + documented stepping-stone
   upgrades — and RN-keychain's **never-downgrade-security** rule for
   migrate-on-read. Their migration code is the distilled lesson of their worst
   outages.

5. **Document the value-size envelope per backend; don't hard-enforce.** Expo's
   "2048-byte limit" was never platform-enforced — a JS warning they *removed*
   in SDK 55, reframing the docs as "we don't enforce a limit, handle native
   errors." State practical expectations (keychain items are small; wincred is
   2560 B; keyutils 32 KiB/key under a 20 KB/200-key quota; our container is
   capped at 16 MiB), and let the backend surface the native error.

6. **A per-store serial execution queue for SecItem calls.**
   `flutter_secure_storage`'s darwin serial queue ended a whole class of
   duplicate-item races. Cheap insurance alongside the in-process mutex.

7. **`Ambiguous` and store-format-vs-data-format error variants** from
   keyring-core — the one place its taxonomy is richer than ours (Flag 5).

8. **Cite the fail-closed precedents.** `git-credential-manager` refuses on
   Linux with no store selected; secure-by-default is now the norm (Python
   moved plaintext keyrings out of core). External validation for our stance in
   the README/design.

### Adapt

9. **Externalized-master-secret pattern → the TPM/portal `KeySource`.**
   libsecret's file backend and the xdg **Secret portal** hand a sandboxed app
   a per-app master secret over an fd, which the app KDF-expands to encrypt its
   own storage — *exactly* our KeySource-wraps-container architecture. That,
   plus systemd-creds for servers, is the blueprint for the headless gap
   (Flag 1). A `portal` KeySource is a concrete future addition.

10. **Security-level *requirement*, not just reporting.** RN-keychain's
    `SECURITY_LEVEL` set-option can *demand* `SECURE_HARDWARE` and fail
    otherwise. When we gain hardware backing, offer a "require hardware /
    fail-closed" mode consistent with our existing resolution stance (Adopt 1
    is the read side of this).

11. **User-presence gating as an optional policy, `biometryCurrentSet` as the
    default.** For app-context backends only. Current-set (invalidates on
    biometric change) is the security-correct default — expo uses it; RN-keychain
    exposes both. Surface the invalidation via the Adopt-2 typed error.

12. **Graceful self-heal as a *caller policy*, not a silent default.** Expo
    silently deletes and returns `null` on an invalidated/missing key — which
    hides data loss (indistinguishable from "never stored"). Surface the typed
    lost/invalidated error and let the caller choose to purge-and-recreate.

13. **Hashed attributes** (libsecret) if we ever add per-item attribute search
    to the container — hash with the derived key rather than storing names.

### Reject

14. **`resetOnError`-style silent wipe as a default**, Windows
    unconditional corrupt-file deletion, web silent-null-on-decrypt-failure
    (`flutter_secure_storage`). Destruction must be explicit, typed, and
    caller-invoked. This is the incumbent's single most user-hostile default,
    adopted *because* its error surface couldn't say "wrong key" — the exact
    thing our matrix says.

15. **Silent security downgrades** — `flutter_secure_storage`'s Secure Enclave
    → plain-keychain fallback; expo's historical CVE-2020-24653
    (`WHEN_UNLOCKED_THIS_DEVICE_ONLY` silently applied a weaker attribute). If a
    requested protection level is unavailable, fail closed with a typed error.

16. **Silent plaintext fallback** — `docker`'s base64-in-`config.json` with a
    warning; `gh`'s fallback to a plaintext token in `hosts.yml` (and #13317:
    it then "silently sends unauthenticated requests"). The anti-pattern our
    fail-closed resolution exists to prevent.

17. **String-only APIs** — everyone's default; causes real silent-null bugs
    (`flutter_secure_storage` reads a non-UTF-8 keychain item as `null`). Keep
    bytes-first.

18. **One-credential-per-service** — RN-keychain's structural limit (a service
    holds one username/password; re-set overwrites; multi-key is faked via the
    `server` axis). We are a true multi-key KV; keep it.

19. **`zalando/go-keyring`'s `/usr/bin/security` CLI on macOS** — defeats
    Keychain ACLs (their #110). Our SecItem FFI is correct.

20. **99designs' JWE file backend as a crypto model** — opaque, non-tunable
    PBKDF2 iterations, no commitment, no atomicity/locking/rollback. Ours is
    strictly better on every one of those.

21. **File-per-entry naming** (`pass`, 99designs) — leaks every entry name as a
    filename. Keep the single values-only container.

22. **`age`'s format as-is** — no key commitment, no rollback field. We add
    both.

23. **Data Protection keychain as the macOS default** — Apple's modern path,
    but it needs a provisioning-profile-authorized entitlement
    (`errSecMissingEntitlement` −34018) that `dart run` and unsigned CLIs can't
    carry; it is exactly the `flutter_secure_storage` macOS pain
    (#804/#1104/#1176). Our classic-login-keychain default "works without a
    Keychain Sharing entitlement" — a real differentiator. Offer DP-keychain
    only as a documented opt-in for signed apps.

24. **iCloud-synchronizable keychain** (`kSecAttrSynchronizable`) as anything
    but an explicit opt-in — contradicts the device-bound threat model, and on
    macOS silently drags you into the entitlement-gated DP keychain.

25. **Floating / runtime-negotiated crypto** — RN-keychain selects cipher by
    API level; MMKV picks 128 vs 256 and truncates the key to 16 bytes. Keep
    the exact pin, the vector firewall, and the explicitly-constructed
    implementation.

26. **Depending on Tink** — wrong language, and its own Android-Keystore
    wrapper is self-described best-effort (it self-tests and disables the
    keystore on flaky devices). Copy its *patterns* (self-test, key-ID
    prefixes), not the dependency.

---

## 4. Peer capsules (reference)

**flutter_secure_storage** (10.3.1, 2026-05; ~3.1M downloads/mo) — the Dart
incumbent; what we'd use if it didn't require Flutter. Wins on breadth (6
platforms), Apple expressiveness (accessibility, iCloud sync, access groups),
biometric/StrongBox/Secure-Enclave options, and a decade of battle-tested
migration machinery. Loses on every rigor axis we care about: String-only (real
silent-null bugs), one stringly `PlatformException` + several silent-null paths
+ a `fatalError` crash path, fail-*open* defaults (`resetOnError` default true,
SE→plain fallback, Windows corrupt-file delete), non-atomic whole-file rewrites
with in-process-only locks, single-JSON-blob-per-keyring-item on Linux, AES-128
data key + no vectors. **Its macOS DP-keychain default is the entitlement pain
we sidestep.** Its most instructive artifacts for us: the backup/restore
data-loss saga and the migration protocol it forced.

**expo-secure-store** (SDK 57 / 57.0.0; ~3.9M downloads/wk) — the most-used RN
secret store. Notable: it **never** used Jetpack EncryptedSharedPreferences
(plain SharedPreferences + AndroidKeyStore AES-256-GCM), so Google's
security-crypto deprecation is a non-event for it — same architecture family as
our Model B. Its backup handling is the mature reference: self-healing reads
(delete + return null since 13.0.2) **plus** shipped backup-exclusion XML wired
via config plugin (since 14.0.0). Its removed 2048-byte limit is the
"document, don't hard-enforce" lesson. String-only; returns `null` on
invalidation (fail-open we'd reject).

**react-native-keychain** (10.0.0, 2025-03) — bare-RN pick. Three concrete
Android ciphers today; **AES-CBC-without-MAC was the default until v9.2.0
(2024)** and is now deprecated (#687) — the cautionary "confidentiality without
integrity" arc that argues for our AEAD+commitment. Ciphertext moved to
DataStore; migrate-on-read never downgrades security. Best ideas to copy:
`getSecurityLevel()` (can *require* `SECURE_HARDWARE`) and the `storage` result
field (reports what backing you got). Worst footgun: one-credential-per-service.
No advisory ever filed.

**react-native-mmkv** (v4, Nitro; ~1.5M downloads/wk) — **not a secret store**,
widely misused as one. Confidentiality-only (AES-CFB + CRC32, no AEAD), key
truncated to 16 bytes, and the `encryptionKey` is a JS string you must yourself
store in a *real* secret store. **CVE-2024-21668**: < 2.11.0 logged the key to
logcat. It is the concrete argument for our "no secret material in
logs/errors" invariant.

**Native iOS/Android** — Android officially deprecated Jetpack Security /
EncryptedSharedPreferences (Apr–Jul 2025) "in favour of … direct use of Android
Keystore," with no successor and no migration guide; the consensus replacement
is Keystore-wrapped-key + your own AES-GCM file/DataStore — **our Model B**.
Google's own **Tink** now treats the Android Keystore as best-effort (it
self-tests and disables it on flaky devices), validating our fail-closed
stance. iOS confirms `kSecUseDataProtectionKeychain` is always-on on iOS (free
for a future iOS backend) and only matters on macOS where it needs the
entitlement (validating our classic-keychain choice). **Square Valet** is the
design benchmark: accessibility required at construction and part of the storage
namespace.

**Rust `keyring`** (v4.1.4, 2026-07) — the gold-standard error taxonomy
(`Ambiguous`, `NotSupportedByStore`, `BadStoreFormat`, …), bytes support
(`get_secret`), native Linux (keyutils + D-Bus, no subprocess), and a headless
`keyutils` store we lack. Behind us on the never-leak-values invariant (attaches
platform errors) and — in 3.x — on fail-closed (mock in-memory fallback when no
backend applies).

**Python `keyring`** (25.7.0) — priority-based backend resolution;
secure-by-default now (plaintext keyrings moved out of core); String-only.
Issue **#457** is the canonical statement of the macOS interpreter-trust-unit
problem that applies to us too. Behind on bytes.

**Go — `zalando/go-keyring`** (0.2.8) — macOS via the `/usr/bin/security` CLI,
which their #110 admits defeats Keychain ACLs (we're clearly ahead here); Linux
pure D-Bus with hard-coded `plain` session; no timeouts (we map locked→typed
error with a hard timeout, which `gh` wraps this library to add). **`gh` CLI**
wraps it with a 3-second timeout (validates our timeout choice) but falls back
to plaintext when the keyring is unavailable (the anti-pattern we reject).

**Go — `99designs/keyring`** (1.2.2, 2022; effectively unmaintained, powers
aws-vault) — its encrypted **file backend** is the closest peer to our
container, and we're ahead on the crypto and durability: JWE with non-tunable
PBKDF2 vs our XChaCha20-Poly1305 + explicit HKDF + key commitment; `WriteFile`
with no atomicity/fsync vs our atomic + dir-fsync; file-per-key (name-leaking)
vs our single values-only container. (Neither has rollback protection.)

**libsecret** — its file backend (portal/TPM master secret, atomic replace,
hashed attributes, encrypt-then-MAC AES-CBC) is a clean design; we're ahead on
AEAD+commitment, roughly even on atomicity, and behind on its externalized-KDF
headless story (the thing our TPM KeySource would close). The **Secret portal**
master-secret pattern is a direct blueprint for a future `portal` KeySource.

**systemd-creds / TPM2** — the best-in-class headless-at-rest primitive
(AES-256-GCM, TPM2 + host-key bound, PCR-bound, ramfs delivery), becoming the
server standard, and integrated by **no** keyring library — so our planned TPM
KeySource would be novel in the peer class.

**pass / age / sops** — `pass` leaks entry names as filenames and has no
locking (we're ahead on both). `age` is a clean AEAD stream but has **no key
commitment and no rollback protection** — the two things our envelope adds.
`sops` solves a different problem (multi-recipient GitOps); its key-group /
Shamir-threshold model is the one idea worth borrowing *if* multi-recipient
ever enters scope (it doesn't today).

---

## 5. Model A vs Model B: what the industry does, by platform

Best practice is **platform-dependent**, and it maps onto one distinction: is
the platform's secure store a *secret store* (holds arbitrary secret bytes,
hardware-gated) or a *key store* (holds keys and performs crypto, but won't
hold arbitrary secret blobs at scale)? Secret store → direct items (**Model
A**). Key store → wrap a key around app-stored ciphertext (**Model B**).

| Platform | Native store is… | Best practice | Why |
|---|---|---|---|
| **iOS** | a *secret* store (Keychain — always Data Protection + Secure Enclave) | **Model A** | Holds arbitrary secrets, hardware-gated, per-item accessibility/access-control. No reason to wrap. |
| **Android** | a *key* store (Keystore holds keys, not secret blobs) | **Model B** | The Keystore can't hold arbitrary secrets at scale; the mandatory pattern is a keystore key encrypting ciphertext in SharedPreferences/DataStore/file. There is effectively **no Model A on Android.** |
| **macOS** | a *secret* store — DP keychain (entitled apps) or legacy login keychain (CLIs) | **A** for entitled apps; **B** for cross-platform / data-heavy / unentitled | DP keychain is best-in-class for signed apps; CLIs get the legacy login keychain (A but 3DES), so data-heavy or security-conscious apps wrap (B). |
| **Linux** | a *secret* store (Secret Service) — when present and unlocked | **A** via Secret Service; **B** for headless / cross-platform | Secret Service holds arbitrary secrets, but may be absent headless and has same-user + legacy-at-rest weaknesses, so servers and cross-platform apps wrap (B). |

**Who uses what:**

- **Model A (direct OS-store items):** the desktop keyring libraries — Python
  `keyring`, `zalando/go-keyring`, Rust `keyring`; credential helpers —
  `git-credential-osxkeychain` / `-libsecret`, `docker-credential-*`; the `gh`
  CLI; Apple's Valet / KeychainAccess; and `flutter_secure_storage`,
  `react-native-keychain`, `expo-secure-store` **on iOS**. The norm on iOS and
  for desktop CLIs.
- **Model B (OS-store key wraps app-encrypted storage):** **all** Android
  secret storage — `flutter_secure_storage` v10, `expo-secure-store`,
  `react-native-keychain`, the former EncryptedSharedPreferences (per-item or
  per-store variants); and **cross-platform desktop apps** — Chromium's "Safe
  Storage" / OSCrypt (a key in the keychain/keyring/DPAPI encrypts its cookie &
  password DB), Electron's `safeStorage` API (Signal Desktop, Slack, VS Code,
  and many more), `99designs/keyring`'s file backend (aws-vault). The norm on
  Android and for data-heavy / cross-platform / headless.
- **Third family — password/passphrase-derived, no OS keystore:** `pass` (gpg),
  `age`, `sops`, `git-credential-store` (plaintext file!), and password
  managers (1Password, Bitwarden — master-password-derived + server sync).
  Right for *user-owned, cross-device* secrets; not for transparent app
  credential storage.
- **Agent model (a fourth framing):** ssh-agent / gpg-agent keep keys in one
  in-memory daemon that clients query. secret_store's stance: the OS keystore
  *is* that agent (securityd, gnome-keyring), so we delegate to it (A) or wrap
  it (B) rather than run our own.

**Where secret_store lands — and why it's correct.** It offers **both**, with A
as the default (`SecretStorage(service:)`) and B as an explicit composition.
That is not a hedge; it's the platform-correct mapping, because best practice
*is* "A where the native store is a secret store, B where it's a key store or
you're headless":

- Our **A default on macOS/Linux** matches the keyring-library and
  credential-helper norm exactly.
- Our **B option** matches the Chromium / Electron `safeStorage` pattern and is
  the only viable approach headless.
- The future **iOS backend should be Model A** (direct keychain), matching every
  iOS library; the future **Android backend must be Model B** (there is no A on
  Android). The `KeySource` / backend seam already accommodates both, so the
  rule to hold as backends land is simply **iOS → A, Android → B.**
