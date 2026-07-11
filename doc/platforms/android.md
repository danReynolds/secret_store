# secret_store on Android

**Requires Android 12 (API 31) or newer.** Older versions throw a typed
`KeystoreUnreachable` rather than degrading.

Every secret lives in **one authenticated encrypted file** in the app-private
files directory (`<dataDir>/files/<appId>/secrets.enc`), sealed with
**XChaCha20-Poly1305** under an HKDF-SHA256-derived key with a key-commitment
header. The 32-byte file key is itself wrapped by an **AES-256-GCM key that
lives inside AndroidKeyStore** (hardware-backed — StrongBox where present, the
TEE otherwise) and never leaves hardware. Only the *wrapped* key blob
(`store-key.wrapped`, a small versioned `SKW1` format) sits beside the
container; the raw file key never touches disk.

**What this resists.** The wrapping key is sealed in secure hardware and never
leaves the device. A stolen disk image, a cloud backup, or a transfer to
another device cannot decrypt the store — the hardware key stays behind.

## Why this is pure Dart (no plugin, no `package:jni`)

Android's Keystore is a Java API with no NDK/C surface, so reaching it normally
means JNI — and the ecosystem's JNI packages require the Flutter SDK, which
would break every Flutter-less server that depends on this package. secret_store
avoids that: Android exports `JNI_GetCreatedJavaVMs` from `libnativehelper` to
apps at **API 31+**, so a hand-rolled `dart:ffi` shim can discover the JVM and
call framework classes directly — **no plugin, no platform channels, no
Flutter-SDK dependency**. The full decision record and the alternatives that
were rejected are in [design.md §12](../design.md).

## Reliability

Android Keystore has a well-known flaky tail; the design is chosen for the
best-case reliability profile and to fail loudly, never silently:

- The wrapping key is generated `setUserAuthenticationRequired(false)` — not
  invalidated by biometric-enrollment changes; the gate is device-level and the
  container adds its own AEAD.
- **StrongBox is attempted, with a TEE fallback** on
  `StrongBoxUnavailableException` (most devices lack StrongBox).
- Every store creation runs a **wrap → unwrap self-test** through the real
  Keystore before anything is persisted — a device with a broken Keystore fails
  at setup, not later at read time.
- If the wrapped-key blob is present but its Keystore key is gone or unusable
  (restore onto a different device, OS/OEM eviction, corruption), reads throw a
  typed **`KeyInvalidated`** instead of silently starting an empty store.
  Recovery is deleting the store's data directory and re-provisioning.
- **Hardware backing is measured, not assumed.** `describe().level` reads the
  KEK's `KeyInfo.getSecurityLevel()`: `hardwareBacked` only when the Keystore
  reports `TRUSTED_ENVIRONMENT` or `STRONGBOX`, otherwise `softwareBacked`
  (a software Keystore implementation, or an emulator). Presence of the
  Keystore is never taken as proof of hardware.

## Exclude the store from backups

Because the wrapping key never migrates, backed-up or transferred store data
can't be decrypted on another device (you'd get `KeyInvalidated`). Excluding the
store directory avoids that confusing restore state and keeps your ciphertext
out of backups. **Security does not depend on this** — restored blobs are
useless without the original device — and since this is a plain Dart package,
not a plugin, it can't inject manifest rules for you. Add them (API 31+):

```xml
<!-- AndroidManifest.xml -->
<application android:dataExtractionRules="@xml/data_extraction_rules" …>
```

```xml
<!-- res/xml/data_extraction_rules.xml — <appId> is the id you pass to
     SecretStorage(appId:) -->
<data-extraction-rules>
  <cloud-backup><exclude domain="file" path="<appId>/" /></cloud-backup>
  <device-transfer><exclude domain="file" path="<appId>/" /></device-transfer>
</data-extraction-rules>
```

The `example_flutter/` app carries these rules as a living example.

**Validation.** The full round-trip and the on-disk shape (container is
ciphertext; only the small wrapped-key blob is beside it) are validated on an
API 33 emulator, including the StrongBox-fallback branch. As with iOS, an
emulator's secure hardware is software-emulated, so the hardware property itself
is pending a one-time physical-device run.
