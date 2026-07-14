# Flutter test demo

This small Flutter application proves that a host-side Flutter test receives
ordinary environment variables through Keyway. The widget reports only
whether the credential is available; it never renders the value.

From this directory:

```sh
flutter pub get
keyway run -- flutter test
keyway set demo-flutter/api-token
keyway run -- flutter test
```

The first run fails closed before Flutter starts. Enter any disposable value
at the hidden prompt, then run the test again. The test verifies the literal
API URL, confirms the credential reached the test process, and confirms its
value does not appear in the widget tree or a failure message. A plain
`flutter test` uses a disposable fixture so the package remains independently
testable; the committed integration marker makes `keyway run` exercise the
real process environment instead.

Clean up afterward:

```sh
keyway rm demo-flutter/api-token
```

This is deliberately a development-test example. A credential embedded in a
mobile application or delivered to a client process is recoverable by that
client; backend service credentials belong on the backend.
