# Dart and Flutter SDK

[Documentation](https://danreynolds.github.io/keybay/docs/) ·
[Architecture](architecture.md) ·
[Security policy](../SECURITY.md) ·
[![CI](https://github.com/danReynolds/keybay/actions/workflows/ci.yml/badge.svg)](https://github.com/danReynolds/keybay/actions/workflows/ci.yml)

Cross-platform secret storage for Dart and Flutter. On iOS, Android 12+, macOS,
and Linux desktop, `SecretStorage(appId:)` automatically applies one documented,
OS-backed storage policy for the current runtime. No Flutter dependency,
account, Keybay server, resident process, or network path is required.

> `0.1.0` is published on pub.dev. Add the SDK with `dart pub add keybay`; the
> CLI ships through Homebrew and `dart install keybay_cli`.

<span id="cli-quickstart"></span>
The CLI now has a dedicated [guide](../packages/keybay_cli/README.md).

## SDK quickstart

Add Keybay to your project:

```sh
dart pub add keybay
```

```dart
import 'package:keybay/keybay.dart';

final store = SecretStorage(appId: 'com.example.myapp');

await store.writeString('api_token', 's3cr3t');
final token = await store.readString('api_token');   // 's3cr3t'
await store.delete('api_token');
```

`SecretStorage(appId:)` has one production knob: `appId` names the logical
store and derives its path or service identity; the runtime selects the fixed
platform scheme. `SecretStorage.withBackend` is the explicit test/custom
integration hatch for callers that construct a backend themselves, not a
weaker mode selected by configuration. Values are bytes (`Uint8List`) at the
core, with `readString`/`writeString` for convenience.

## How your secrets are protected

`SecretStorage(appId:)` picks the scheme for you and is **fail-closed**: when
the required platform store is unavailable, it throws rather than substituting
plaintext storage or a plaintext store key beside the encrypted container.
Apple native-item paths delegate protection to the Data Protection Keychain.
File paths use an authenticated container, so a wrong key or tampering fails
before plaintext is returned. Each platform link has the full breakdown.

| Platform | Secrets live in | Protected by |
|---|---|---|
| [iOS](platforms/ios.md) | native Data Protection Keychain items | fixed device-bound, non-synchronizing item policy; hardware backing is not attested |
| [macOS — entitled app](platforms/macos.md#signed-apps-entitled) | native Data Protection Keychain items | the same fixed item policy; hardware backing is not attested |
| [macOS — CLI / unentitled app](platforms/macos.md#command-line-and-unentitled) | an authenticated encrypted file | 32-byte store key in the login Keychain; login-bound |
| [Android 12+](platforms/android.md) | an authenticated encrypted file | store key wrapped by Android Keystore; StrongBox requested and actual level inspected |
| [Linux desktop](platforms/linux.md) | an authenticated encrypted file | 32-byte store key in an unlocked Secret Service provider; login-bound |

Every row is exercised end-to-end through its genuine platform API or service
(see [Testing](#testing)). Windows is not implemented and fails closed:

| Platform | Planned scheme |
|---|---|
| Windows | encrypted file; key in DPAPI / Credential Manager |

Headless deployments have no supported Keybay backend or availability
contract. A desktop resolver may still reach a configured credential service;
an absent or locked service fails typed. Deployments should use their
platform's own secret system. The removed prototype and rationale remain in
[the research plan](headless-implementation-plan.md).

## Threat model

**Protects against** direct plaintext disclosure from the Keybay container,
backup, or dotfile sync; other local users; casual disclosure (scrollback,
`ps` argv); and a wrong or swapped store key (the key-committing container
fails closed before decryption). On macOS and Linux file paths, offline
confidentiality is bounded by the strength of the login or keyring password.

**Does not protect against** same-user malware while the keystore is unlocked;
process-memory disclosure, including swap and core dumps (the package scrubs its
own native staging buffers, which it can, but key material also transits
GC-managed heaps — the Dart heap, and on Android the intermediate Java arrays —
which can't be reliably zeroed and are not claimed to be); rollback to an older
genuine container (AEAD is not anti-rollback); timing side-channels in pure-Dart
crypto; root. Concurrent writes are **coordinated**: same-isolate handles
serialize on a per-path FIFO mutex, and every mutating operation additionally
takes an exclusive advisory `flock` that excludes other isolates *and* other processes
(so a lost update, or two first-writers minting rival store keys, cannot happen
on a filesystem that honors `flock` — local app-data storage does). There is
**no key escrow**: on the encrypted-file path, losing its store-key item makes
that container unreadable.

The bar is ssh-agent / aws-vault, not an HSM. Full derivation and the crypto/FFI
engineering practices are in [design.md](design.md).

## Encrypted-file cryptography

An XChaCha20-Poly1305 (AEAD) container with an HKDF-SHA256-derived
**key-commitment** header — a wrong key fails closed *before* decryption, and
multi-key ciphertext games are ruled out. `Random.secure()` only. Everything
runs through `package:cryptography`, exact-pinned and constructed as concrete
`Dart*` implementations (so the global crypto locator can't swap them), and is
exercised against RFC 8439 / RFC 5869 / draft-arciszewski test vectors plus
edge cases in this package's own suite, so incompatible primitive behavior is
caught before the exact dependency pin moves. A CI canary fails when a newer
`cryptography` release appears, so the pin moves only by reviewed decision.
These checks make dependency and behavior changes visible; they do not prove
that a dependency is uncompromised.

## Testing

The bar is **every supported platform path exercised through its genuine API or
service**, repeatably, from the suite — not mocks.

```sh
./tool/test.sh          # format + analyze + unit + this-machine keystore integration
./tool/test_linux.sh    # Linux Secret Service, against real gnome-keyring in Docker
./tool/test_e2e.sh      # the full real-platform matrix (--entitled adds the macOS DP path)
```

In CI, on every push to main and every pull request: the unit tier (crypto
vectors, container fuzzing, real POSIX permissions, dependency-closure
firewall) plus the real macOS Keychain and Linux Secret Service. The mobile
and entitled-macOS legs need device toolchains and a signing identity, so they
run locally via `tool/test_e2e.sh`, which boots and tears down the iOS
simulator and Android emulator itself. One honest limit: on a
simulator/emulator the secure hardware is *emulated*, so those legs prove the
real keystore **code path** end-to-end, not that physical silicon mediated it.

## Requirements

- Dart SDK ≥ 3.6.
- **Desktop:** macOS or Linux (Windows is unsupported). Linux needs
  `secret-tool` and a Secret Service provider — see [the Linux
  notes](platforms/linux.md).
- **Mobile (inside a Flutter app):** iOS, or Android 12 (API 31)+.
- One exact-pinned third-party runtime dependency, `cryptography`; the rest of
  the closure is dart-lang official, and a test fails CI if the tree changes.
  Because that pin is exact, an app depending — directly or transitively — on a
  different `cryptography` version won't resolve until the versions align; the
  pin is a deliberate supply-chain control ([design.md](design.md) §10),
  not an oversight.

## Status

`0.1.0` is published on pub.dev. The API and on-disk container format may still
change; a future `0.2.0` may carry breaking changes under pub's pre-1.0
semantics. Implemented and
validated end-to-end against the genuine platform path: macOS (CLI and
entitled), Linux, iOS, and Android 12+. Windows is unsupported and fails typed.
Headless operation has no supported backend or availability contract.
Report vulnerabilities per [SECURITY.md](../SECURITY.md); design rationale is in
[design.md](design.md) and [architecture.md](architecture.md), with the current
product comparison in [ecosystem-comparison.md](ecosystem-comparison.md).

## License

MIT.
