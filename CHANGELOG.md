# Changelog

## 0.1.0 (unreleased)

Initial implementation (see [doc/design.md](doc/design.md)). Not yet published.

### Headless hardware-bound key source (pre-release)

- **`TpmKeySource`** wraps the container store key with `systemd-creds` and
  writes only the *encrypted* blob to disk — hardware-bound to the TPM on a
  machine that has one, so a stolen disk is useless without that host's chip.
  It's the headless analogue of `SystemKeySource` (drop it into
  `SecretStorage.encryptedFile(keySource: …)`; the container is unchanged),
  turning headless from S4 (key on disk) to S1. `TpmKeyBinding` selects
  `host+tpm2` (default, strongest), `tpm2`, or `host` (documented as *not*
  hardware-bound); the TPM-requiring defaults **fail closed** without a TPM
  rather than silently degrading. Unit-tested over a fake `ProcessRunner`;
  the real `systemd-creds` round-trip is integration-tested (Linux, `host`
  binding) and verified in Docker.
- **`ProcessRunner` extracted** to `src/ffi/process_runner.dart` (was in the
  `secret-tool` file) — now shared by the Secret Service backend and the TPM
  key source. Public export path changed accordingly.

### Key-source surface: secure-only (pre-release)

- **`KeystoreKeySource` renamed to `SystemKeySource`** (dropped the `Key…Key`
  stutter; pairs with `TpmKeySource`).
- **`FileKeySource` and `InMemoryKeySource` un-exported.** The public sources
  are now the two secure ones (`SystemKeySource`, `TpmKeySource`); the insecure
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
