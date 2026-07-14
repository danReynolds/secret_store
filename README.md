# keyway

Cross-platform secret storage for Dart — **pure Dart, no Flutter required**.
One API keeps each secret in the strongest place the operating system offers:
hardware-backed secure storage where it exists, an authenticated encrypted file
everywhere else. It runs anywhere Dart does — command-line tools, servers, and
Flutter apps.

Dart didn't have this. `flutter_secure_storage` needs Flutter, so a CLI or
server can't use it; Python, Go, and Rust each have a `keyring`. This is
Dart's — and it reaches even Android's hardware Keystore without pulling in a
Flutter dependency, so a headless server can still depend on it.

```sh
dart pub add keyway
```

```dart
import 'package:keyway/keyway.dart';

final store = SecretStorage(appId: 'com.example.myapp');

await store.writeString('api_token', 's3cr3t', label: 'API token');
final token = await store.readString('api_token');   // 's3cr3t'
await store.delete('api_token');
```

`appId` is the only knob — it selects the platform scheme and derives where
everything lives. No configuration, no footguns. Values are bytes
(`Uint8List`) at the core, with `readString`/`writeString` for convenience.

## Keyway CLI

The separately packaged [`keyway_cli`](packages/keyway_cli) product gives any
language the same local store through five commands: `run`, `set`, `rm`,
`list`, and `doctor`. A committed mixed manifest keeps ordinary configuration
literal and replaces secret values with explicit, qualified `kw://`
references. `keyway run -- COMMAND` resolves the references and replaces
itself with exactly that command—no account, server, daemon, shell hook, or
resident wrapper.

The executable quickstart in
[`packages/keyway_cli/example/quickstart`](packages/keyway_cli/example/quickstart)
is exercised against the real macOS and Linux stores in CI.

Source-checkout demos in [`demo`](demo) show the same CLI contract around a
Flutter widget test, a Rails runner, and a Node service. The applications read
ordinary environment variables and have no Keyway dependency.

## How your secrets are protected

`SecretStorage(appId:)` picks the scheme for you and is **fail-closed**: with
nowhere safe for the key, it throws rather than quietly downgrade. Every secret
is sealed with authenticated encryption, so a wrong key or any tampering fails
before decryption. Each platform link has the full breakdown.

| Platform | Secrets live in | Protected by |
|---|---|---|
| [iOS](doc/platforms/ios.md) | native keychain items | Secure Enclave (device hardware) |
| [macOS — app](doc/platforms/macos.md#signed-apps-entitled) | native keychain items | Secure Enclave (device hardware) |
| [macOS — CLI](doc/platforms/macos.md#command-line-and-unentitled) | an encrypted file | key in the login Keychain |
| [Android](doc/platforms/android.md) | an encrypted file | key sealed in hardware (Keystore — TEE / StrongBox) |
| [Linux](doc/platforms/linux.md) | an encrypted file | key in the Secret Service (GNOME Keyring / KWallet) |

Every row is validated end-to-end against the real platform keystore (see
[Testing](#testing)). Two platforms are planned; until they ship they fail
closed with a typed error:

| Platform | Planned scheme |
|---|---|
| Windows | encrypted file; key in DPAPI / Credential Manager |
| [Headless servers](doc/headless-implementation-plan.md) | encrypted file; key TPM-sealed via `systemd-creds` |

## Threat model

**Protects against** plaintext key material on disk (backup / Time-Machine /
dotfile-sync leaks), offline disk theft without full-disk encryption, other
local users, casual disclosure (scrollback, `ps` argv), and a wrong or swapped
store key (the key-committing container fails closed before decryption).

**Does not protect against** same-user malware while the keystore is unlocked;
process-memory disclosure, including swap and core dumps (the package scrubs its
own native staging buffers, which it can, but key material also transits
GC-managed heaps — the Dart heap, and on Android the intermediate Java arrays —
which can't be reliably zeroed and are not claimed to be); rollback to an older
genuine container (AEAD is not anti-rollback); timing side-channels in pure-Dart
crypto; root. Concurrent writes are **coordinated**: same-isolate handles serialize on a
per-path FIFO mutex, and every mutating operation additionally takes an
exclusive advisory `flock` that excludes other isolates *and* other processes
(so a lost update, or two first-writers minting rival store keys, cannot happen
on a filesystem that honors `flock` — local app-data storage does). There is
**no key escrow** — lose the keystore item and you lose the store.

The bar is ssh-agent / aws-vault, not an HSM. Full derivation and the crypto/FFI
engineering practices are in [doc/design.md](doc/design.md).

## Cryptography

An XChaCha20-Poly1305 (AEAD) container with an HKDF-SHA256-derived
**key-commitment** header — a wrong key fails closed *before* decryption, and
multi-key ciphertext games are ruled out. `Random.secure()` only. Everything
runs through `package:cryptography`, exact-pinned and constructed as concrete
`Dart*` implementations (so the global crypto locator can't swap them), and is
exercised against RFC 8439 / RFC 5869 / draft-arciszewski test vectors plus
edge cases in this package's own suite — a buggy or compromised dependency
update can't pass silently. A CI canary fails when a newer `cryptography`
release appears, so the pin moves only by reviewed decision.

## Testing

The bar is **every supported platform exercised against its real keystore**
(simulator/emulator count for mobile), repeatably, from the suite — not mocks.

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
- **Desktop / server:** macOS or Linux (Windows planned). Linux needs
  `secret-tool` and a Secret Service provider — see [the Linux
  notes](doc/platforms/linux.md).
- **Mobile (inside a Flutter app):** iOS, or Android 12 (API 31)+.
- One exact-pinned third-party runtime dependency, `cryptography`; the rest of
  the closure is dart-lang official, and a test fails CI if the tree changes.
  Because that pin is exact, an app depending — directly or transitively — on a
  different `cryptography` version won't resolve until the versions align; the
  pin is a deliberate supply-chain control ([doc/design.md](doc/design.md) §10),
  not an oversight.

## Status

`0.1.0` is the first pub.dev release. It is pre-1.0, so the API and on-disk
container format may still change — under pub's `^0.1.0` semantics a `0.2.0`
may carry breaking changes. Shipping today, each validated end-to-end against
its real keystore: macOS (CLI and entitled), Linux, iOS, and Android 12+.
Windows and headless servers are planned and fail closed until they land.
Report vulnerabilities per [SECURITY.md](SECURITY.md); design rationale is in
[doc/design.md](doc/design.md) and [doc/architecture.md](doc/architecture.md),
with a cross-ecosystem comparison in
[doc/ecosystem-comparison.md](doc/ecosystem-comparison.md).

## License

MIT.
