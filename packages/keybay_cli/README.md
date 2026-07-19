# keybay CLI

Five commands for local, run-scoped secret injection on macOS and Linux
desktop. No account, Keybay server, resident Keybay process, network access,
or shell hook. Keybay writes no plaintext secret file.

Keybay keeps non-secret configuration literal in a committed manifest and
stores secret values behind explicit `kb://` references:

```dotenv
API_URL=https://staging.example.com
LOG_LEVEL=debug
OPENAI_API_KEY=kb://acme-api/openai-api-key
```

```sh
keybay set acme-api/openai-api-key
keybay run -- npm start
```

The launched process receives ordinary environment variables and needs no
Keybay library. Keybay replaces itself with the child via `execve`; it never
invokes a shell or stays resident as a wrapper.

## Install

The signed Homebrew binary is the promoted release channel because its stable
macOS code identity is part of the login-Keychain access contract:

> The entire 0.1.0 GitHub release predates immutable-release verification. Its
> macOS binary also fails strict code-signature verification and launch on
> macOS 26. Do not treat any 0.1.0 GitHub asset as satisfying the verification
> contract below, and do not use its macOS binary; wait for the patch release.

```sh
brew install danreynolds/tap/keybay
```

Or install the native `keybay` executable through Dart:

```sh
dart install keybay_cli
```

The Dart channel builds and installs a native `keybay` executable. Dart is
needed to install or update it, not to launch it afterward. Follow Dart's
notice if its install-bin directory is not already on `PATH`.

On macOS, this pub.dev channel does not promise the frozen Developer ID
identity used by the promoted Homebrew archive. Its ad-hoc/shared-runtime
identity can change across installs, so existing login-Keychain items can fail
closed after an update. Use the signed Homebrew channel when cross-release
Keychain continuity matters.

Contributors can run the in-tree package directly from a source checkout
instead:

```sh
dart pub get
dart pub global activate --source path packages/keybay_cli
```

For repeated contributor runs without changing global state, use the repository
runner documented in the [examples guide](example/README.md).

### Verify a release download

Release integrity is machine-checkable end to end. Every GitHub release ships
`SHA256SUMS`; each executable archive has GitHub build provenance; and the
immutable release has a separate attestation covering its tag, commit, and
assets. macOS binaries are Developer ID-signed, hardened-runtime, and
notarized. Verify a downloaded archive before extracting it — a link someone
hands you is not a provenance chain. Use GitHub CLI 2.93.0 or newer; older
versions are affected by
[GHSA-8xvp-7hj6-mcj9](https://github.com/cli/cli/security/advisories/GHSA-8xvp-7hj6-mcj9):

```sh
VERSION=X.Y.Z
OS=linux
ARCH=x64
GH_VERSION="$(gh --version | awk 'NR == 1 { print $3 }')"
if [[ "$(printf '%s\n' 2.93.0 "$GH_VERSION" | sort -V | head -1)" != 2.93.0 ]]; then
  echo "GitHub CLI 2.93.0 or newer is required" >&2
  exit 1
fi

# 1. The release must be immutable and the local file must be one of its assets.
gh release verify "keybay_cli-v$VERSION" --repo danReynolds/keybay
gh release verify-asset "keybay_cli-v$VERSION" \
  "keybay-$VERSION-$OS-$ARCH.tar.gz" --repo danReynolds/keybay

# 2. The archive must match the release's published checksums.
#    (macOS: `shasum -a 256 --check --ignore-missing SHA256SUMS`)
sha256sum --check --ignore-missing SHA256SUMS

# 3. The archive must prove it was built by this repository's release
#    workflow from the tag you expect (uses the GitHub CLI).
gh attestation verify "keybay-$VERSION-$OS-$ARCH.tar.gz" \
  --repo danReynolds/keybay \
  --signer-workflow danReynolds/keybay/.github/workflows/release_cli.yml \
  --source-ref "refs/tags/keybay_cli-v$VERSION" \
  --deny-self-hosted-runners
```

The other channels carry their own verification: Homebrew checks archives
against SHA-256 values pinned in the formula, `dart install keybay_cli` resolves
through pub.dev's content-hash verification, and the release pipeline verifies
the macOS binary's exact Developer ID requirement and online notarization
ticket.

On Linux, Keybay requires the `secret-tool` client and an unlocked desktop
Secret Service provider. Homebrew installs its `libsecret` dependency; distro
or Dart/archive installs should install `libsecret-tools` (Debian/Ubuntu) or
the equivalent package. Headless deployment is unsupported; without a
reachable, unlocked desktop Secret Service provider, operations fail typed.

Under `dart run`, the shared Dart VM—not Keybay alone—is the macOS keychain
trust unit. `keybay doctor` makes the runtime distinction visible.

## Quickstart

The source checkout and native release archives include the same
language-neutral executable example. Use
`packages/keybay_cli/example/quickstart` in a source checkout or
`example/quickstart` in an extracted native archive. The
[repository examples guide](https://github.com/danReynolds/keybay/tree/main/packages/keybay_cli/example)
distinguishes an installed `keybay` from the current source checkout; choose
one before running these commands:

```sh
cp secrets.env.example .secrets.env
keybay run -- ./app.sh
keybay set acme-example/openai-api-key
keybay run -- ./app.sh
```

The first `run` fails closed and prints the required `set` command without
launching the app. Enter any disposable value at the hidden prompt. The second
`run` safely shows the literal URL and reports the secret as available without
printing its value. The generated `.secrets.env` contains only a public literal
and a reference; real projects should commit manifests like this so every
developer shares the contract but supplies their own value.

After this disposable example:

```sh
keybay rm acme-example/openai-api-key
rm .secrets.env
```

## Commands

```text
keybay run [-f FILE] -- COMMAND [ARGS...]
keybay set [--stdin] KEY
keybay rm KEY
keybay list
keybay doctor
```

Every key is qualified and at most 120 ASCII characters:
`organization-project/name` for project-local values or
`organization-shared/name` for deliberate reuse. Identical full keys share a
value across repositories; namespaces organize identity but are not an access
control boundary.

`set` never accepts a value argument. Interactive input requires a TTY and is
hidden; automation pipes strict UTF-8. The two modes never cross: `--stdin` at
a terminal is refused (typing there would echo the secret into scrollback), and
empty input is rejected rather than stored, so a silently failed producer in a
pipeline cannot replace a real credential with the empty string:

```sh
op read 'op://Engineering/OpenAI/credential' |
  keybay set --stdin acme-api/openai-api-key
```

`rm` is idempotent and silent. `list` prints sorted qualified names only,
one per line. A failed `run` lists every missing key and launches nothing.

## Manifest

Keybay reads exactly one file: `./.secrets.env`, or the file selected by
`-f`. It never searches parent directories and never writes a manifest.

The grammar is intentionally smaller than dotenv:

- strict UTF-8; LF or CRLF; one leading BOM tolerated
- `NAME=VALUE`, comments, and blank lines
- ASCII space/tab trimming around values
- no quotes, escapes, interpolation, `export`, continuations, or inline
  comments
- a value beginning `kb://` must be a valid qualified reference
- duplicate environment names are errors

Literals are committed plaintext. Keybay cannot determine whether a literal is
actually a secret; that classification remains visible in review.

## Security boundary

Keybay keeps referenced values out of repositories, argv, its own output, and
interactive shell state. It preserves the parent environment **byte-exact** —
variables the manifest does not name pass through from the raw process
`environ`, including values that are not valid UTF-8 — overlays only variables
named by the selected manifest, resolves all references before launch, and has
no network code. The launched command starts with shell-default signal state
(the Dart VM's ignored SIGPIPE and blocked job-control signals are reset at the
exec boundary), so pipelines behave as they would from a shell.

After injection, values are normal child environment variables. They can be
inherited by descendants and may be visible to same-user process inspection,
crash dumps, or the child itself. Running a manifest trusts both its references
and the launched code. Direct use of the `keybay` Dart library is preferable
when an application can avoid environment injection entirely.

macOS and Linux desktop are supported. Headless/CI environments have no
supported availability contract; use the CI platform's secret store there. See the
[recovery procedure](https://github.com/danReynolds/keybay/blob/main/doc/cli-recovery.md)
before abandoning an unreadable store.

## License

MIT.
