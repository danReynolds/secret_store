# example_flutter — keyway integration harness

Not a demo app. This is `keyway`'s living, runnable proof that the package
works from inside a real Flutter app bundle against the **real** platform
keystore on each mobile/desktop target — the coverage a pure-Dart CLI test can't
reach — and the reference for the Android backup-exclusion rules.

## What it exercises

`integration_test/keyway_test.dart` runs `SecretStorage(appId:)` end to
end — full round-trip (bytes, strings, labels, enumeration, idempotent delete),
shared backing across two instances, unicode values — and asserts that the
per-platform resolver picked the scheme and security level that environment must
get. Each leg passes `--dart-define=EXPECT_SCHEME` / `EXPECT_LEVEL` so detection
is *checked*, not trusted:

- **macOS .app (ad-hoc signed):** encrypted file + `loginBound` — the −34018
  branch every CLI takes, here inside a real sandboxed bundle.
- **macOS entitled (Keychain Sharing + dev signing):** native DP items +
  `hardwareBacked` — the DP success branch. Also proves the migration guard:
  a pre-existing file container makes an entitled resolve throw
  `MigrationRequired`.
- **iOS simulator:** native DP items + `hardwareBacked` (Xcode 15+ sims emulate
  the Secure Enclave).
- **Android emulator (API 31+):** encrypted file + AndroidKeyStore-wrapped key
  via the pure-FFI JNI shim; the level is measured from the KEK after a write
  (`softwareBacked` on an emulator), and a dedicated test confirms ciphertext +
  the versioned wrapped-key blob land at the derived path.

## Running

Drive the whole matrix with **`tool/test_e2e.sh`** from the repo root (`--entitled`
adds the signed macOS DP-success leg). It boots the simulator/emulator, applies
and restores the entitled macOS overlay, and reports a per-leg pass/fail table.
Requires a macOS dev box with Xcode + an iPhone simulator, the Android SDK + an
AVD, Flutter, and Docker.

## Android backup exclusion

`android/app/src/main/res/xml/data_extraction_rules.xml` is the living example of
the backup-exclusion documented in the package's
[`doc/platforms/android.md`](../doc/platforms/android.md). The
wrapping key is hardware-bound and never migrates, so backed-up/transferred store
data can't be decrypted on another device (reported as `KeyInvalidated`);
excluding the store directory from cloud backup and device transfer avoids that
confusing restore state and keeps ciphertext out of backups.
