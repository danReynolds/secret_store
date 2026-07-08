# secret_store

Platform-keystore secret storage for Dart **without Flutter** — macOS Keychain
and Linux Secret Service, plus an authenticated encrypted-file container, behind
one small async API.

`flutter_secure_storage` is a Flutter plugin, so a CLI or server can't use it.
Python, Go, and Rust each have a `keyring` library; this is Dart's. Pure Dart +
FFI, no platform channels — it runs in CLIs, servers, and Flutter apps alike.

```dart
import 'package:secret_store/secret_store.dart';

final store = SecretStorage(service: 'com.example.myapp');

await store.writeString('api_token', 's3cr3t', label: 'API token');
final token = await store.readString('api_token');   // 's3cr3t'
await store.delete('api_token');
```

`read`/`write` are bytes-first (`Uint8List`); `readString`/`writeString` are the
convenience tier. The core keeps values as `Uint8List` rather than routing them
through interned `String`s — though note Dart's GC can't zero heap memory, so
this is copy-minimisation, not a zeroing guarantee (see the threat model).

## How your data is protected at rest

You express intent; the library picks the strongest backing the platform
offers. `SecretStorage(service:)` uses the OS keystore, **fail-closed** (on a
platform with no usable keystore it throws rather than silently degrading), and
`describe()` reports what you got. But *how strong* "at rest" actually is
depends on the device — this is the part to understand before you rely on it.

Two layers are in play. If you use the **encrypted-file** store, your secrets
are always sealed with **XChaCha20-Poly1305 + HKDF + a key-commitment header**;
what varies per platform is how the **wrapping key** (or, for direct keystore
items, the secret itself) is protected:

| Platform | Zero-config default | Key protected at rest by | Strength | Hardware-backed option |
|---|---|---|---|---|
| **macOS** | login Keychain | **3DES-CBC** under a key derived from your **login password** (PBKDF2-HMAC-SHA1); no entitlement needed, works from `dart run` | password-bound (S3) | **DP keychain + Secure Enclave** — AES-256-GCM, non-exportable hardware key (**S1**), for a signed + entitled app |
| **Linux (desktop)** | Secret Service | **gnome-keyring** AES-128-CBC / **KWallet** Blowfish; readable by any same-user process while the keyring is unlocked | password-bound (S3) | — (no mainstream desktop HSM path) |
| **Linux (headless)** | *fail-closed* (no desktop keyring) | `TpmKeySource`: **systemd-creds AES-256-GCM, TPM-sealed** — the on-disk container is useless without that host's TPM chip | **hardware (S1)** | this *is* the option; falls back to nothing (you supply the key) if there's no TPM |
| **Windows / iOS / Android** | *planned* | — | — | — |

`S1…S3` are the tiers from [doc/design.md](doc/design.md) (S1 hardware-bound →
S3 legacy-cipher-under-a-password). Takeaways: on macOS and Linux desktop the
default is **as strong as the user's login password** (the cipher is legacy but
that's rarely the weak link); the **hardware-backed** paths are the macOS DP
keychain and the Linux TPM source; and against a **stolen disk**, only the S1
rows resist offline attack.

**macOS hardware backing (opt-in).** A signed app with the Keychain Sharing
entitlement gets the DP keychain in one line — no access group to configure:
`SecretStorage(service: 'com.example.app', api: MacKeychainApi.dataProtection())`.
It fails loudly (−34018) if the entitlement isn't present, never silently falls
back. *(Refusal path CI-tested; the entitled-app success path is verified
manually — CI can't sign a bundle.)*

### Encrypted file (headless, one backup unit, or many secrets)

Where there's no unlocked keyring (a headless server) or you want a single
encrypted file, store everything in one authenticated container sealed by a key
you place explicitly — the key's home is the one genuine security decision:

```dart
final store = SecretStorage.encryptedFile(
  path: '$stateDir/secrets.enc',
  keySource: SystemKeySource(service: 'myapp/$profileId', api: platformKeystore()),
  contextSalt: utf8.encode(profileId),   // binds the container to this profile
);
```

Two secure key sources ship: **`SystemKeySource`** (the key lives in the OS
keystore — the per-platform strengths above) and **`TpmKeySource`**
(hardware-bound via `systemd-creds` for headless servers). Anything else —
bring-your-own-key from a KMS, a password prompt, or an orchestrator-injected
secret — is a `KeySource` you implement (four small methods; use the exported
`SecureFileSystem` if you must touch disk). There is deliberately **no
ready-made plaintext-key-on-disk source** to grab by accident.

## Threat model

**Protects against** plaintext key material on disk (backup / Time-Machine /
dotfile-sync leaks), offline disk theft without full-disk encryption, other local
users, casual disclosure (scrollback, `ps` argv), and a wrong or swapped store key
(key-committing container — fails closed before decryption).

**Does not protect against** same-user malware while the keystore is unlocked;
process-memory disclosure, including swap and core dumps (Dart-heap buffers
cannot be zeroed; the package's own native staging buffers *are* zeroed, but
decrypted copies in the GC heap remain); rollback to an older genuine container
(out of scope — AEAD is not anti-rollback; closing it would need a
keystore-anchored counter, a possible v2); concurrent writes from multiple
processes (a container is single-writer — bring your own lock); timing
side-channels in pure-Dart crypto; root. There is **no key escrow** — losing
the keystore item loses the store.

**macOS: know your trust unit.** Keychain ACLs bind to the *acting binary*.
Under `dart run` that binary is the shared Dart VM, so one "Always Allow"
authorizes every Dart script you ever run to read the item silently. For
production, `dart compile exe` and sign with a stable Developer ID — the ACL
then binds to your app and survives upgrades. (Login-keychain items are also
3DES-encrypted at rest; the AES-256-GCM Data Protection keychain requires a
provisioned, entitlement-carrying app and is unavailable to plain CLIs.)
Headless/CI consumers: construct `MacKeychainApi(nonInteractive: true)` to get
a typed `KeystoreLocked` instead of a GUI unlock prompt.

The bar is ssh-agent / aws-vault, not an HSM. Full derivation and the crypto/FFI
engineering practices are in [doc/design.md](doc/design.md).

## Requirements

- Dart SDK ≥ 3.6, macOS or Linux.
- Linux: `secret-tool` (Debian/Ubuntu: `libsecret-tools`) and a Secret Service
  provider (GNOME Keyring or KWallet ≥ 5.97).
- One third-party runtime dependency, exact-pinned: `cryptography`. The full
  runtime closure is `{cryptography, ffi, collection, crypto, meta, typed_data}`
  — everything but `cryptography` is dart-lang official, and a test fails CI if
  the tree changes.

## Cryptography

XChaCha20-Poly1305 (AEAD) container with an HKDF-derived **key-commitment**
header (wrong key ≠ tamper, and multi-key ciphertext games fail closed);
HKDF-SHA256 key derivation; `Random.secure()`
only. All via `package:cryptography` (exact-pinned, concrete `Dart*`
implementations constructed directly so the global `Cryptography.instance`
locator cannot swap them), exercised against RFC 8439 / RFC 5869 /
draft-arciszewski vectors plus empty-AAD and block-boundary edge cases in this
package's own suite, so a buggy or compromised dependency update cannot pass
silently. A CI canary fails when a newer `cryptography` release appears, so
the pin moves only by reviewed decision.

## Testing

Three tiers, all run in CI on every push; each is re-runnable locally:

```sh
./tool/test.sh          # format + analyze + unit + this-platform keystore integration
./tool/test_linux.sh    # Linux Secret Service tier, against real gnome-keyring in Docker
```

`tool/test.sh` is the one-command pre-push suite (it wraps
`dart test` and `SECRET_STORE_INTEGRATION=1 dart test -t integration`).

The unit tier (crypto vectors, container/fuzz, POSIX permissions on the real
filesystem, backend logic over fakes, dependency-closure firewall) needs no
keystore. Integration tests exercise the real macOS Keychain / Linux Secret
Service, are opt-in (`SECRET_STORE_INTEGRATION=1`), and are platform-gated
(`@TestOn`), so `-t integration` runs whichever applies to the machine you're
on. `tool/test_linux.sh` runs the Linux tier against a real gnome-keyring in an
ubuntu container, so you can regression-test the Linux backend from a Mac. The
macOS Data Protection keychain **success** path can't be automated (it needs a
signed, provisioned app bundle); [tool/dp_keychain_verification.md](tool/dp_keychain_verification.md)
is the manual procedure.

## Status

Pre-1.0 and not yet published to pub.dev; the API and on-disk container format
may still change before 1.0. Report vulnerabilities per [SECURITY.md](SECURITY.md);
the design rationale is in [doc/design.md](doc/design.md), and a benchmark against
best-in-class secret storage across ecosystems (native iOS/Android,
`flutter_secure_storage`, React Native, and the Rust/Python/Go keyring peers) is
in [doc/ecosystem-comparison.md](doc/ecosystem-comparison.md).

## License

MIT.
