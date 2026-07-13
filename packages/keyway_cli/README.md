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

The signed GitHub/Homebrew binary is the promoted channel because its stable
macOS code identity is also part of the login-Keychain access contract:

```sh
brew install danreynolds/tap/keyway
```

Dart users can install the package directly:

```sh
dart install keyway_cli
```

Under `dart run`, the shared Dart VM—not Keyway alone—is the macOS keychain
trust unit. `keyway doctor` makes the runtime distinction visible.

## Quickstart

The source package and native release archives include a language-neutral
executable example. Use `packages/keyway_cli/example/quickstart` in a source
checkout or `example/quickstart` in an extracted native archive, then run these
commands exactly:

```sh
cp secrets.env.example .secrets.env
keyway run -- ./verify.sh
keyway set acme-example/openai-api-key
keyway run -- ./verify.sh
```

The first `run` fails closed and prints the required `set` command without
launching the script. Enter any disposable value at the hidden prompt. The
second `run` prints `Keyway quickstart passed.` without revealing the value.

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
