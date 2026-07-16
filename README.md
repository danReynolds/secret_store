<img src="https://danreynolds.github.io/keybay/assets/keybay-mark.svg" alt="" width="64" height="64">

# Keybay

**[Read the documentation →](https://danreynolds.github.io/keybay/docs/)**

[CLI guide](https://danreynolds.github.io/keybay/docs/cli/) ·
[Dart and Flutter SDK](https://danreynolds.github.io/keybay/docs/guide/) ·
[Security design](https://danreynolds.github.io/keybay/docs/design/)

Keybay keeps local secret values protected behind each supported operating
system's credential infrastructure. Its five-command CLI launches any local
process with resolved environment variables on macOS and Linux desktop; its
Dart and Flutter SDK provides direct storage across those platforms, iOS, and
Android 12+.

No account, hosted service, daemon, network path, or shell hook.

> **0.1.0 pre-release:** Keybay is not yet published to pub.dev, GitHub
> Releases, or Homebrew. Evaluate it from a reviewed source checkout.

## CLI

Commit references, not secret values.

**`.secrets.env`**

```dotenv
API_URL=https://staging.example.com
OPENAI_API_KEY=kb://acme-example/openai-api-key
```

**Terminal**

```sh
keybay set acme-example/openai-api-key
keybay run -- ./app.sh
```

Referenced values become ordinary environment variables in the launched
process. Namespaces identify values; they are not access-control boundaries.

**[Install and use the CLI →](https://danreynolds.github.io/keybay/docs/cli/)**

## Dart and Flutter

```dart
import 'package:keybay/keybay.dart';

final store = SecretStorage(appId: 'com.example.app');
await store.writeString('api-token', tokenFromOAuth);
final stored = await store.readString('api-token');
```

`appId` names the logical store; the runtime selects Keybay's fixed platform
policy.

**[Use the SDK →](https://danreynolds.github.io/keybay/docs/guide/)**

## Security

- Native Keychain items where supported; otherwise an authenticated encrypted
  file whose key is protected by the operating system's credential store.
- Unavailable, locked, inconsistent, corrupt, tampered, and unsupported stores
  fail closed. No plaintext fallback is substituted.
- Protection ends after retrieval or environment injection. Same-user malware,
  rollback, and root remain outside the threat model.
- Apple hardware backing is not attested. Android reports the observed
  wrapping-key security level. Windows and headless deployments are unsupported.

**[Read the security design →](https://danreynolds.github.io/keybay/docs/design/)**

Report vulnerabilities through the
[private reporting process](https://danreynolds.github.io/keybay/docs/security/#reporting).

## License

MIT.
