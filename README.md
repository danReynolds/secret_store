<img src="https://danreynolds.github.io/keybay/assets/keybay-mark.svg" alt="" width="64" height="64">

# Keybay

Keep local secrets out of your repository and in an OS-protected store.

**[See how Keybay works →](https://danreynolds.github.io/keybay/)**

Installation, quickstarts, platform support, and the security design live on
the Keybay site.

Use the five-command CLI to run local processes with the secrets they need on
macOS and Linux desktop, or store values directly with the Dart and Flutter SDK
on macOS, Linux desktop, iOS, and Android 12+.

No Keybay account or hosted service. No Keybay daemon, network path, or shell
hook.

> **Pre-1.0.** The `keybay` and `keybay_cli` 0.1.0 packages are on pub.dev, and
> native archives/Homebrew are published. The 0.1.0 GitHub release predates
> immutable-release verification, and its macOS binary does not pass strict
> code-signature verification or launch on macOS 26. Do not use that macOS
> artifact as a current release. Evaluate from a reviewed source checkout or
> wait for the hardened patch release.

## CLI

Commit the reference, not the value.

```dotenv
OPENAI_API_KEY=kb://my-app/openai-api-key
```

```sh
keybay set my-app/openai-api-key
keybay run -- ./app
```

CLI values live in one per-user store. Namespaces prevent naming collisions;
they are not access-control boundaries.

**[Use the CLI →](https://danreynolds.github.io/keybay/docs/cli/)**

## Dart and Flutter

```dart
import 'package:keybay/keybay.dart';

final store = SecretStorage(appId: 'com.example.app');
await store.writeString('api-token', tokenFromOAuth);
final token = await store.readString('api-token');
```

**[Use the SDK →](https://danreynolds.github.io/keybay/docs/guide/)**

## Security

Keybay uses native keychain storage where supported. Elsewhere, it uses an
authenticated encrypted file whose key is protected by the operating system's
credential store. If the required store is unavailable, locked, invalidated,
corrupt, tampered with, or unsupported, Keybay fails closed. It never falls
back to plaintext.

Protection ends when a value is read or injected into a process. Same-user
malware, rollback, and root remain outside the threat model. Windows and
headless deployments are unsupported.

[Read the security design →](https://danreynolds.github.io/keybay/docs/design/) ·
[Report a vulnerability](https://danreynolds.github.io/keybay/docs/security/#reporting)

MIT licensed.
