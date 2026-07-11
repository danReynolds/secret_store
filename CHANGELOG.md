# Changelog

## 0.1.0 (unreleased)

Initial implementation (see [doc/design.md](doc/design.md)). Not yet published.

### Hardening from code review (pre-release)

Correctness and honesty fixes from an external review; all now covered by
tests (unit + the real-platform e2e matrix). The cryptographic core was
unchanged — these are lifecycle/ownership and truthful-reporting fixes.

- **`describe().level` is now measured, not asserted.** Added
  `SecurityLevel.softwareBacked`. Android inspects the KEK's
  `KeyInfo.getSecurityLevel()` and reports `hardwareBacked` only for
  `TRUSTED_ENVIRONMENT`/`STRONGBOX` (emulators and software Keystores report
  `softwareBacked`). Apple native items report `hardwareBacked` as the
  platform-mechanism claim — the DP keychain has no per-item residency query
  and the simulator/pre-T2-Intel exceptions aren't detectable from pure Dart
  FFI, so they're documented with the silicon check pending an on-device run.
  The level is now owned by the key source (where the key lives), not a backend
  constant.
- **macOS entitlement changes no longer switch stores silently.** A `.scheme`
  marker records how a store was provisioned; if a later run resolves to a
  different scheme (entitlement gained/lost), the resolver throws the new typed
  **`MigrationRequired`** rather than showing an empty store or resurfacing
  stale values.
- **Oversized writes can't brick a store.** `write` now rejects a value whose
  sealed container would exceed the read cap with the new typed
  **`StoreTooLarge`**, *before* replacing the existing container (which stays
  intact and readable).
- **Same-store serialization is per container path**, not per backend object —
  two `SecretStorage(appId:)` instances in one process no longer drop each
  other's updates.
- **The macOS DP probe can no longer touch a caller's item**: it uses a
  dedicated internal service outside the public `appId` grammar and only
  removes its own probe item.
- **Linux fixes:** the `appId` reaches `secret-tool` after a `--` option
  terminator (a leading-dash id can't be parsed as a flag); and a clean account
  with no `~/.local/share` now has the XDG data hierarchy created `0700`
  instead of failing the first write.
- **Android filesystem errors are typed**: the POSIX shim resolves the errno
  symbol across libcs (`__errno_location` on glibc/musl, `__errno` on bionic)
  instead of a fixed guess.

### Android backend (pre-release)

- **Android (12 / API 31+) now resolves to the encrypted file with its key
  wrapped by an AndroidKeyStore hardware key** (AES-256-GCM KEK; StrongBox
  when present, TEE otherwise; `setUserAuthenticationRequired(false)` — the
  reliability-first profile), reported as `hardwareBacked`. Below API 31 the
  resolver throws typed guidance.
- **Pure `dart:ffi` — no plugin, no platform channels, no `package:jni`, zero
  new dependencies.** VM discovery via `libnativehelper`'s
  `JNI_GetCreatedJavaVMs` (officially app-visible at API 31+); a ~24-function
  hand-rolled JNI shim drives boot-classpath framework classes only. Decision
  record with the full alternatives analysis: doc/design.md §12. This keeps
  the package resolvable by Flutter-less CLIs/servers — the constraint every
  jni-based route breaks.
- **Write-time self-test**: every store creation wrap→unwrap→compares through
  the real Keystore before anything is persisted (fail closed on the
  broken-Keystore device tail; no silent software fallback).
- New typed error **`KeyInvalidated`**: a present wrapped-key blob whose
  Keystore key is gone or fails to unwrap (backup restored onto a different
  device — hardware keys never migrate — OS/OEM key eviction, or blob
  corruption) is reported loudly instead of silently starting an empty store.
- Container path is derived **without an Android Context** (no hidden APIs):
  `System.getProperty("java.io.tmpdir")` → `<dataDir>/files/<appId>/`.
- README "Android notes" documents **backup exclusion**
  (`dataExtractionRules`) with snippets; `example_flutter/` carries them as a
  living example. Validated end-to-end on an API 33 emulator (real
  AndroidKeyStore, StrongBox-fallback branch included).

### iOS backend (pre-release)

- **iOS now resolves to native Data Protection keychain items** — Secure
  Enclave, `hardwareBacked`. No probe (the DP keychain is the only keychain on
  iOS; every app can use it via the implicit default access group). Items are
  created `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (device-bound,
  never restored to another device, readable by background work after first
  unlock) with `synchronizable=false`.
- The macOS keychain binding was generalized to `AppleKeychainApi` (was
  `MacKeychainApi`) and loads Security.framework symbols from the process image
  on iOS (`DynamicLibrary.process()`) vs absolute-path `dlopen` on macOS — same
  SecItem code otherwise. Internal rename; the type is not exported.
- Added `example_flutter/`, a Flutter host app carrying the mobile + desktop
  integration tiers (also the living proof the package runs inside Flutter with
  **zero** CocoaPods plugins). Round-trip validated on the iOS simulator; the
  Secure-Enclave hardware property is pending a one-time on-device run.

### One-input API + per-platform resolver (pre-release; supersedes the earlier constructor surface described below)

- **The production surface is now exactly `SecretStorage(appId:)`.** The
  resolver derives everything from the validated `appId` and picks the
  strongest scheme per platform: on macOS a once-per-process **Data Protection
  probe** selects native Secure-Enclave keychain items for entitled apps, or
  (on `errSecMissingEntitlement` −34018 — the normal CLI result) the encrypted
  file with its key in the login Keychain; any *other* DP failure throws loud.
  Linux composes the encrypted file + Secret Service key. Anything else throws
  `KeystoreUnreachable` with guidance. `describe()` now reports a
  **`SecurityLevel`** (`hardwareBacked` / `loginBound`).
- **appId is traversal-proof by grammar** (`[A-Za-z0-9._-]{1,120}`, must
  contain an alphanumeric — no `/`, and `.`/`..` are unrepresentable), because
  it names the derived data directory
  (`~/Library/Application Support/<appId>/` on macOS,
  `${XDG_DATA_HOME:-~/.local/share}/<appId>/` on Linux) and the keystore
  service.
- **Removed** (breaking, pre-release): the `service:`/`api:` parameters,
  `SecretStorage.encryptedFile(...)`, `contextSalt`, the
  `MacKeychainApi(nonInteractive:)` knob (the fail-fast non-interactive
  behavior is now unconditional), `platformKeystore()`, and the exported
  key-source/binding/shim surface (`SystemKeySource`, `TpmKeySource`,
  `KeySource`, `MacKeychainApi`, `SecretToolApi`, `KeystoreApi`,
  `SecureFileSystem`, `ProcessRunner`, …). Public API =
  `SecretStorage` + verbs, the error taxonomy, and the
  `SecretBackend`/`BackendInfo`/`BackendCapabilities`/`SecurityLevel`
  describe/test surface.

### Headless / TPM: out of scope (pre-release)

- A `TpmKeySource` (store key wrapped by `systemd-creds`, TPM-sealed) was
  built and validated against real `systemd-creds`, then **removed from the
  tree** before release — headless is out of scope for now, and unreachable
  code in a security package is unjustified surface. The design survives in
  doc/headless-implementation-plan.md (and the implementation in git history)
  should demand appear. Headless boxes fail closed with a typed error.
- **`ProcessRunner` extracted** to `src/ffi/process_runner.dart` (was in the
  `secret-tool` file), injectable for tests.

### Key-source surface: secure-only (pre-release)

- **`KeystoreKeySource` renamed to `SystemKeySource`** (dropped the `Key…Key`
  stutter).
- **`FileKeySource` and `InMemoryKeySource` un-exported.** The insecure
  plaintext-key-on-disk source and the non-persistent test double stay in
  `src/` (reference impl + test double). Bring-your-own-key or an on-disk key is
  served by implementing the public `KeySource` interface (with the exported
  `SecureFileSystem` for 0600 hygiene) — so an insecure choice is one you write
  deliberately, never grab from autocomplete. README now documents at-rest
  protection per platform.

### Security hardening pass (pre-release; container format changed while unshipped)

- **Key commitment in the container format.** XChaCha20-Poly1305 is not
  key-committing, so the header now carries a 32-byte HKDF-derived
  key-commitment value, checked in constant time before decryption. New typed
  error `WrongStoreKey` makes "wrong key/context" reliably distinct from
  "tampered" (`AuthenticationFailed`). **Pre-release format break**: existing
  dev containers must be recreated.
- **In-process write serialization.** `EncryptedFileBackend` operations run
  under a FIFO mutex, so concurrent calls within a process never interleave
  their whole-file read-modify-write. Cross-process coordination is out of
  scope — a container is single-writer.
- **Native staging buffers zeroed** before free in the POSIX write path and
  the Keychain `CFData` path (Dart-heap memory still can't be scrubbed; FFI
  memory can, so it is).
- **Read-side permission enforcement.** Container, key file, and store
  directory are refused on *read* when group/other-accessible (OpenSSH
  stance); non-regular files (FIFO) refused; container writes now end with a
  best-effort directory fsync so the rename survives a power cut.
- **Pinned crypto implementations.** The container constructs
  `DartXchacha20`/`DartHkdf` directly instead of the `Cryptography.instance`
  factories, so a host app swapping the global instance (e.g.
  `flutter_cryptography`) cannot substitute an un-vector-tested
  implementation. Added RFC 8439 §2.8.2 vector and empty-AAD/empty-plaintext/
  block-boundary AEAD edge tests.
- **Validation hardening.** Labels reject control characters (C0/DEL) and are
  length-capped; validation errors no longer echo the offending value (a
  transposed `(key, secret)` argument pair must not leak into logs).
- **macOS.** `MacKeychainApi(nonInteractive: true)` adds per-call
  `kSecUseAuthenticationUIFail` so a locked keychain fails fast as
  `KeystoreLocked` instead of raising a GUI prompt (headless/CI). Default
  item label now matches Linux (`secret_store`).
- **CI.** Actions pinned by commit SHA; the OSV job now uses the reusable
  workflow correctly (the old `osv-scanner-action@v1` reference was dangling);
  a canary job fails when pub.dev publishes a `cryptography` release newer
  than the pin, forcing a reviewed bump.

### Austerity pass (pre-release; first-principles removal of speculative surface)

- **Cut the generation counter.** It provided no rollback protection on its own
  (a counter bound in the AAD is only tamper-evident); rollback resistance, if
  built, is a versioned v2 with a keystore-anchored counter. Removes a header
  field and the `ContainerData` wrapper — `Container.open` returns the entry
  map directly again. **Format break** (folds into the pre-release change
  above).
- **Cut the cross-process `flock`.** Removed `SecureFileSystem.tryFlockSync`,
  `AdvisoryFileLock`, the `StoreContended` error, and the `lockTimeout` option
  — surface for a race the single-writer contract avoids. The in-process mutex
  stays.
- **Cut the hand-rolled base64 codec** in favour of `dart:convert` — it was a
  maintained crypto-adjacent artifact to avoid one `String` copy the GC can't
  zero anyway. `ProcessRunner.stdin` is a `String` again (breaking for custom
  runners); subprocess *output* stays bytes for scrubbing.
- **Simplified label validation** to control-char + length (dropped the Unicode
  format/bidi-category machinery — heavier than the keystore-UI-spoof threat).

### Linux backend fixes (found by the real integration test)

- **`delete` is now idempotent against real gnome-keyring.** `secret-tool clear`
  exits 1 (not 0) when nothing matched; `delete` no longer treats that as a
  failure. The mocked unit test had encoded the wrong exit code.
- **`getAll` now enumerates correctly.** `secret-tool search` prints account
  attributes to **stderr** (secrets go to stdout); `getAll` parses stderr (and
  stdout defensively), then scrubs both. It previously scanned only stdout and
  found nothing.
- **New Linux integration test** (`test/secret_service_integration_test.dart`)
  runs under `dbus-run-session` against a real gnome-keyring in CI — verified
  locally in a Docker ubuntu container. This is what caught the two bugs above.

### Intent-first public API (pre-release)

- **The concrete backends are no longer exported.** `KeystoreBackend` and
  `EncryptedFileBackend` are hidden — which mechanism to use is the library's
  per-platform decision, not the caller's. The public surface is three
  constructors: `SecretStorage(service:, {api})` (the secure default; `api`
  is the advanced binding override, whose one use is opting an entitled macOS
  app up to the Data Protection keychain), `SecretStorage.encryptedFile(path:,
  keySource:, contextSalt:)` (headless / one-file — replaces
  `withBackend(EncryptedFileBackend(...))`), and `withBackend(...)` (test /
  custom escape hatch). `describe()` reports which mechanism was chosen.

- **macOS Data Protection keychain opt-in.** `MacKeychainApi.dataProtection()`
  targets the DP keychain (AES-256-GCM + Secure Enclave) for a signed, entitled
  app: `SecretStorage(service: s, api: MacKeychainApi.dataProtection())`. Uses
  the app's implicit default access group (Xcode's Keychain Sharing capability
  is all that's needed — no access group to configure). An unentitled process
  is refused with `errSecMissingEntitlement` (−34018) → `KeystoreUnreachable`,
  never silently falling back to the login keychain. The refusal path is
  integration-tested on the unsigned CI runner; the entitled-app success path
  is verified manually (CI can't sign an app bundle).

- **Front API** — `SecretStorage`: bytes-first async key/value with String
  conveniences, identifier/label validation, capability-guarded enumeration.
  Default `SecretStorage(service:)` resolves the platform keystore (fail-closed
  off macOS/Linux).
- **Backends** (`SecretBackend` seam, honest `capabilities`):
  - `KeystoreBackend` — direct OS-keystore items (model A). macOS via
    `MacKeychainApi` (direct `SecItem` FFI, validated against the real login
    Keychain); Linux via `SecretToolApi` (`secret-tool`, stdin transport, hard
    timeout, output scrubbing).
  - `EncryptedFileBackend` — XChaCha20-Poly1305 authenticated container with
    HKDF-SHA256 key derivation, binary TLV payload, profile-bound AAD, atomic
    0600-from-birth writes; the full §7 failure matrix as distinct typed errors.
- **Key sources**: `KeystoreKeySource` (model B — key in the OS keystore,
  container encrypted on disk; dune's default), `FileKeySource` (explicit
  insecure fallback), `InMemoryKeySource`.
- **Security**: `Random.secure()` only; RFC 8439 / RFC 5869 / draft-arciszewski
  vectors run against the pinned `cryptography`; one third-party runtime
  dependency, enforced by a dependency-closure test.
