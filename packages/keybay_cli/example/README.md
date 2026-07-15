# Keybay CLI examples

These are all examples of the CLI process boundary:

- [`quickstart`](quickstart): the packaged language-neutral acceptance path
- [`flutter`](flutter): launch a macOS Flutter app with injected configuration
- [`rails`](rails): boot a Rails web app on the loopback interface
- [`node`](node): start a Node web app on the loopback interface

Each example contains a manifest template with public configuration and
`kb://` references only. Copy it to `.secrets.env` as instructed; every
developer supplies their own values through the local Keybay store. The
examples use different qualified namespaces, so their disposable values do
not bleed into one another.

The three visual app examples intentionally render the injected value so you
can see the complete process boundary working. Use a disposable value only:
the value can appear on screen, in screenshots, or in browser tooling. The
language-neutral quickstart keeps its terminal output redacted.

## Choose the executable first

For an installed release, install the native executable and follow Dart's
`PATH` notice if it prints one:

```sh
dart install keybay_cli
keybay --version
```

For the current source checkout, do not install a stale snapshot. Resolve the
workspace and define the source runner once from the repository root:

```sh
dart pub get
alias keybay="$PWD/tool/keybay-dev"
```

Then enter any example directory and use the same command name:

```sh
cd packages/keybay_cli/example/flutter
keybay --version
```

`keybay-dev` runs the current source with the root package configuration while
preserving the example directory as the manifest directory. On macOS, the
shared Dart VM is the Keychain trust unit for this source mode; the signed
installed binary has its own stable identity. The runner is contributor
tooling, not a sixth CLI command and not part of a release archive.

Dart also supports global activation from the local package path:

```sh
dart pub global activate --source path packages/keybay_cli
```

That is convenient when global state and Pub's dependency-resolution output on
each invocation are acceptable. It can shadow an installed release; remove it
with `dart pub global deactivate keybay_cli`. The repository-local runner above
is the quieter default for source development.

Now follow the selected README. Run every command from that example directory;
Keybay deliberately reads only its manifest and never searches parents.
Remove the disposable value with the documented `keybay rm` command when
finished.
