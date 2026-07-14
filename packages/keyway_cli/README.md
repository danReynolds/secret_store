# keyway CLI

Five commands for local, run-scoped secret injection. No account, server,
daemon, network access, shell hook, or plaintext secret file.

Keyway keeps non-secret configuration literal in a committed manifest and
stores secret values behind explicit `kw://` references:

```dotenv
API_URL=https://staging.example.com
LOG_LEVEL=debug
OPENAI_API_KEY=kw://acme-api/openai-api-key
```

```sh
keyway set acme-api/openai-api-key
keyway run -- npm start
```

The launched process receives ordinary environment variables and needs no
Keyway library. Keyway replaces itself with the child via `execve`; it never
invokes a shell or stays resident as a wrapper.

## Install

`0.1.0` is not published yet. From a source checkout, install the current local
package:

```sh
dart pub get
dart pub global activate --source path packages/keyway_cli
```

For repeated contributor runs without changing global state, use the repository
runner documented in the [examples guide](example/README.md).

The signed GitHub/Homebrew binary will be the promoted release channel because
its stable macOS code identity is part of the login-Keychain access contract:

```sh
# Available after the signed 0.1.0 release, not today:
brew install danreynolds/tap/keyway
dart install keyway_cli
```

The Dart channel builds and installs a native `keyway` executable. Dart is
needed to install or update it, not to launch it afterward. Follow Dart's
notice if its install-bin directory is not already on `PATH`.

On Linux, Keyway requires the `secret-tool` client and an unlocked desktop
Secret Service provider. Homebrew installs its `libsecret` dependency; distro
or Dart/archive installs should install `libsecret-tools` (Debian/Ubuntu) or
the equivalent package. A headless session still fails closed by design.

Under `dart run`, the shared Dart VM—not Keyway alone—is the macOS keychain
trust unit. `keyway doctor` makes the runtime distinction visible.

## Quickstart

The source checkout includes a language-neutral executable example; future
native release archives will include it too. Use
`packages/keyway_cli/example/quickstart` in a source checkout or
`example/quickstart` in an extracted native archive. The
[repository examples guide](https://github.com/danReynolds/keyway/tree/main/packages/keyway_cli/example)
distinguishes an installed `keyway` from the current source checkout; choose
one before running these commands:

```sh
cp secrets.env.example .secrets.env
keyway run -- ./app.sh
keyway set acme-example/openai-api-key
keyway run -- ./app.sh
```

The first `run` fails closed and prints the required `set` command without
launching the app. Enter any disposable value at the hidden prompt. The second
`run` safely shows the literal URL and reports the secret as available without
printing its value. The generated `.secrets.env` contains only a public literal
and a reference; real projects should commit manifests like this so every
developer shares the contract but supplies their own value.

After this disposable example:

```sh
keyway rm acme-example/openai-api-key
rm .secrets.env
```

## Commands

```text
keyway run [-f FILE] -- COMMAND [ARGS...]
keyway set [--stdin] KEY
keyway rm KEY
keyway list
keyway doctor
```

Every key is qualified and at most 120 ASCII characters:
`organization-project/name` for project-local values or
`organization-shared/name` for deliberate reuse. Identical full keys share a
value across repositories; namespaces organize identity but are not an access
control boundary.

`set` never accepts a value argument. Interactive input requires a TTY and is
hidden; automation pipes strict UTF-8:

```sh
op read 'op://Engineering/OpenAI/credential' |
  keyway set --stdin acme-api/openai-api-key
```

`rm` is idempotent and silent. `list` prints sorted qualified names only,
one per line. A failed `run` lists every missing key and launches nothing.

## Manifest

Keyway reads exactly one file: `./.secrets.env`, or the file selected by
`-f`. It never searches parent directories and never writes a manifest.

The grammar is intentionally smaller than dotenv:

- strict UTF-8; LF or CRLF; one leading BOM tolerated
- `NAME=VALUE`, comments, and blank lines
- ASCII space/tab trimming around values
- no quotes, escapes, interpolation, `export`, continuations, or inline
  comments
- a value beginning `kw://` must be a valid qualified reference
- duplicate environment names are errors

Literals are committed plaintext. Keyway cannot determine whether a literal is
actually a secret; that classification remains visible in review.

## Security boundary

Keyway keeps referenced values out of repositories, argv, its own output, and
interactive shell state. It injects only variables named by the selected
manifest, resolves all references before launch, and has no network code.

After injection, values are normal child environment variables. They can be
inherited by descendants and may be visible to same-user process inspection,
crash dumps, or the child itself. Running a manifest trusts both its references
and the launched code. Direct use of the `keyway` Dart library is preferable
when an application can avoid environment injection entirely.

macOS and Linux desktop are supported. Headless/CI environments fail closed;
use the CI platform's secret store there. See the
[recovery procedure](https://github.com/danReynolds/keyway/blob/main/doc/cli-recovery.md)
before abandoning an unreadable store.

## License

MIT.

Keyway for Dart is not affiliated with the separate hosted product at
[keyway.sh](https://keyway.sh/).
