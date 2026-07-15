# Flutter app example

This macOS Flutter application receives ordinary environment variables through
Keybay and renders the injected disposable value in a real app window.

First choose an installed or source-checkout executable as described in the
[examples guide](../README.md). Then, from this directory:

```sh
flutter pub get
cp secrets.env.example .secrets.env
keybay run -- flutter run -d macos
keybay set keybay-flutter/api-token
keybay run -- flutter run -d macos
```

The first run fails closed before Flutter starts. Enter a disposable value at
the hidden prompt, then run again. The launched window displays the public API
URL and the exact disposable value inherited by the app process. Stop the app
with Control-C. A plain `flutter test` verifies the same widget independently;
running that test through Keybay exercises the real process environment.

This example intentionally puts the full value on screen. It can appear in
screenshots or accessibility tooling, so never enter a production credential.

Clean up afterward:

```sh
keybay rm keybay-flutter/api-token
rm .secrets.env
```

This is deliberately a desktop development example. A credential embedded in
a mobile application or delivered to a client process is recoverable by that
client; backend service credentials belong on the backend.
