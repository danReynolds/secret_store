# Keybay release runbook

Keybay releases are deliberately tag-triggered and one-way. A maintainer makes
three decisions; GitHub Actions performs the rest:

1. merge one reviewed, green release commit;
2. sign and push the core tag, then wait for its green workflow and pub.dev;
3. from the same commit, sign and push the CLI tag.

There is no merge bot, PAT for tag pushes, GitHub releases, or pub.dev,
mutable artifact promotion, or combined "publish both" command. The sole
non-Apple long-lived CI secret is the narrow cross-repository Homebrew tap
token. An owner-created, signed tag is the human authorization boundary.

## One-time repository setup

Keep each credential in the one job that needs it.

| GitHub environment | Allowed tags | Contents |
|---|---|---|
| `macos-signing` | `keybay_cli-v*` | `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD` |
| `macos-notarization` | `keybay_cli-v*` | secret `APPLE_NOTARY_KEY_P8_BASE64`; variables `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` |
| `homebrew-tap` | `keybay_cli-v*` | `HOMEBREW_TAP_TOKEN`, scoped to Contents write on `danReynolds/homebrew-tap` only |
| `pub.dev` | `v*`, `keybay_cli-v*` | no publisher secret; pub.dev exchanges GitHub OIDC |

The Apple Team ID (`5AHFA9FUZG`) and code identifier
(`io.github.danreynolds.keybay.cli`) are reviewed workflow constants, not
secrets. The signing job derives the only acceptable certificate fingerprint
from the P12 after proving it is a Developer ID Application identity for that
team.

Release tags must be SSH-signed by the dedicated key with fingerprint
`SHA256:4ozSnfVaMzZ/qrzo51I8FPKawmZSIojAB5Ll+qhguFM`. The local release tool
checks the configured public key and verifies the new tag before pushing; both
workflows independently verify the byte-exact GitHub tag payload and signature.
A GitHub web-flow signature is not sufficient. Rotate this key only through a
reviewed workflow-and-runbook change before using the replacement key.

Register that public key with GitHub as an SSH **signing** key, then configure
the clean release checkout:

```sh
git config gpg.format ssh
git config user.signingKey /absolute/path/to/keybay-release-signing.pub
install -m 0755 tool/keybay-release ~/.pub-cache/bin/keybay-release
ssh-keygen -lf /absolute/path/to/keybay-release-signing.pub
```

The final fingerprint must be the frozen value above. The launcher deliberately
resolves `tool/release.dart` from the current checkout rather than installing a
stale copy of the release logic.

Use deployment tag restrictions on every environment. Do not add an approval
click performed by the same maintainer: the locally signed tag already records
that decision, and self-approval adds delay without independent review. Add an
environment reviewer only when a genuinely independent second person will
review releases.

Also configure the repository once:

- protect `main` with the existing CI and review rules;
- require Actions to be pinned to full commit SHAs;
- enable immutable releases;
- add one no-bypass tag ruleset for `v*` and `keybay_cli-v*` that blocks tag
  updates and deletion;
- add a separate creation ruleset for the same patterns that permits only the
  `danReynolds` GitHub account to create them;
- keep direct repository write access owner-only. GitHub lets any writer create
  a Release for an existing tag, and tag rulesets do not govern Release objects;
  adding a writer therefore grants release authority. If direct collaborators
  become necessary, move binary publication to a separate owner/bot-only
  distribution repository;
- configure pub.dev trusted publishing for package `keybay`: repository
  `danReynolds/keybay`, tag pattern `v{{version}}`, and required environment
  `pub.dev`;
- configure pub.dev trusted publishing for package `keybay_cli`: repository
  `danReynolds/keybay`, tag pattern `keybay_cli-v{{version}}`, and required
  environment `pub.dev`. Workflow filenames are repository-side details, not
  pub.dev trust inputs;
- retain linear history and no force-push/delete on the Homebrew tap.

The owner-only creation rule is not optional. GitHub executes a tag-push
workflow from the tagged commit, so an ordinary writer must not be able to tag
an off-main commit that replaces the checks before requesting an environment.
The separate no-bypass ruleset keeps even the owner from moving or deleting a
tag after creation. Repository administration remains the unavoidable GitHub
root of trust; the frozen SSH signature adds local intent and an auditable key.

GitHub does not reveal stored secret values, so names alone do not prove a safe
migration. Complete this gate before creating any `v*` or `keybay_cli-v*` tag:

1. Merge the hardened workflows first; do not put credentials into jobs from an
   older commit.
2. Obtain the canonical credentials or issue fresh ones. In disposable local
   state, prove that the P12/password imports as exactly one Developer ID
   Application identity for Team `5AHFA9FUZG`; the P8/key ID/issuer tuple can
   authenticate `xcrun notarytool history`; and the Homebrew token is restricted
   to `danReynolds/homebrew-tap` with only Metadata read and Contents read/write.
3. Enter those values into the three narrow environments above, verify every
   name and deployment tag restriction, and remove the disposable local copies.
4. Only after those checks pass, delete the old all-purpose `release`
   environment.

This is a pre-tag gate, not cleanup after a test release. The core tag can
publish successfully through OIDC before absent or incorrect CLI credentials
are discovered, and a bad Homebrew token is reached only after GitHub has
published the immutable CLI release. Never delete the old environment first.

## Prepare and authorize a release

The core and CLI versions move in lockstep. The core pubspec, CLI pubspec,
CLI's exact core dependency, and `keybay --version` constant must agree.

```sh
keybay-release release patch       # creates and pushes release/vX.Y.Z + PR
```

Replace both changelog placeholders, wait for CI, review, and merge. Then use a
clean checkout of the merged commit:

```sh
keybay-release publish core
# Wait for publish.yml to pass and for the core version to be live on pub.dev.
keybay-release publish cli
```

`publish core` fetches `origin/main` and refuses unless `HEAD` is its exact
current tip. It creates signed annotated tag `vX.Y.Z`, then uses a leased
atomic push to reject a `main` it already observes as advanced. The workflow
independently rechecks the exact remote tip after the push.

Do not merge another PR between pushing the core tag and the core workflow
accepting it. If `main` advances first, the append-only tag is intentionally
stranded; release a new patch version instead of moving or deleting the tag.

`publish cli` fetches the remote core tag and refuses unless `HEAD` is exactly
that tag's peeled commit and the commit remains on `origin/main`. It creates and
pushes signed annotated tag `keybay_cli-vX.Y.Z`. Main may have advanced while
pub.dev processed the core; the CLI must still use the exact reviewed core
source commit.

Useful read-only commands:

```sh
keybay-release status
keybay-release check
keybay-release publish core --dry-run
keybay-release publish cli --dry-run
```

## What automation proves

### Core tag

`publish.yml` rejects a lightweight, unverified, wrong-version, or stale-main
tag. A no-credential job runs formatting, analysis, tests, and pub archive
validation. Only the small final job receives `id-token: write`, checks out the
same commit afresh, and publishes `packages/keybay` through pub.dev OIDC. A
retry reconstructs the package archive and accepts an already-hosted version
only when every path, type, mode, and file byte matches that tagged source.

### CLI tag

`release_cli.yml` performs this sequence:

1. Validate both verified annotated tags, exact source/version agreement, main
   ancestry, the exact successful core-publish run, the hosted core archive,
   tests, and the CLI package archive. The prior core workflow validated its
   own package archive.
2. Build arm64/x64 Linux and macOS candidates with Dart `3.12.2`.
3. Execute Linux candidates on credential-free runners.
4. In one `macos-signing` job, import only the P12, sign both candidates, destroy
   the temporary keychain and P12, then verify the frozen identity. This job has
   no checkout, Dart SDK, publisher token, or notary key and never executes a
   candidate.
5. Execute the exact signed candidates and the real Keychain quickstart on
   older/current arm64 and Intel macOS runners. These jobs have no release
   secret.
6. Package fresh copies of the accepted bytes on Linux. Packaging is structural
   and never executes a candidate.
7. In one `macos-notarization` job, compare the packaged bytes to the signer
   hashes, submit both architectures in one ZIP, validate Apple's accepted log,
   destroy the P8, and then verify both online tickets. This job has no P12,
   checkout, Dart SDK, or publisher token and never executes a candidate.
8. Attest the four final archives, create one draft with the complete payload,
   then publish it once. Repository immutability locks the release, tag, and
   assets and creates GitHub's separate release attestation.
9. Re-download and verify the immutable Linux release, checksum, and build
   provenance; execute it with no token or Dart. Only then update Homebrew.
10. Install and exercise the public Homebrew formula. Publish `keybay_cli` to
    pub.dev through OIDC last.

Build and acceptance are separate only where the boundary buys something: a
fresh candidate runner cannot inherit signing/notary/publishing credentials or
build-workspace mutations. Signing, notarization, and publication are separate
because no single job should hold two release authorities. The cost is several
small jobs; no custom release service or broad release token is added. The
narrow Homebrew token exists only because the tap is a different repository.

## macOS identity and notarization

Signing answers "which Apple-registered developer produced these bytes?" and
binds Keychain access to a stable code identity. Every release binary must have:

- identifier `io.github.danreynolds.keybay.cli`;
- Team ID `5AHFA9FUZG` and Developer ID Application authority;
- secure timestamp and hardened runtime;
- no entitlements; and
- this exact generated designated requirement:

```text
designated => identifier "io.github.danreynolds.keybay.cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "5AHFA9FUZG"
```

Notarization is a separate Apple malware/policy scan and online ticket. Apple
does not staple a ticket to a standalone Mach-O executable, so Keybay does not
add an app bundle, disk image, or installer merely to gain stapling. The gate is
Apple's log matching the submitted ZIP hash, `Accepted` status, no issues, both
architectures, followed by
`codesign -R='notarized' --check-notarization` after the P8 has been destroyed.
`spctl --assess` is not treated as a reliable standalone-executable contract.

The frozen requirement is the continuity anchor. The workflow also exercises a
real Keychain round trip with every signed candidate, but it does not claim that
a same-run round trip independently proves cross-release upgrade continuity.

## Failure policy

- Before publication, rerun the same tag only for transient credentials,
  settings, runner, or network failures that do not change source or workflow
  bytes. A source/workflow fix requires a new patch version. If an upload
  failure leaves a draft, confirm it was never published, delete that draft,
  and rerun.
- After a successful GitHub publication, rerun only failed downstream jobs for
  transient Homebrew or pub.dev failures. If a lost response makes the publish
  job rerun, it accepts the existing release only after proving it is immutable
  and every asset byte exactly matches this workflow run; it never alters it.
- A pub.dev retry likewise rebuilds the exact package archive. If the version
  already exists, it succeeds only after comparing every package path, type,
  mode, and file byte; a mismatch fails closed. Otherwise it uploads that same
  locally validated archive, so publication cannot race a second archive build.
- Never move a release tag, replace an asset, use `--clobber`, or repair a public
  release in place. If published bytes are wrong, cut a new patch version.
- A skipped architecture, rejected Apple log, failed public-channel receipt, or
  missing pub.dev publication is an incomplete release, not a warning.

The entire `0.1.0` GitHub release predates immutable releases and cannot satisfy
the verification contract below on any OS. In addition, its macOS archives have
matching published SHA-256 values and Apple logs and passed the old macOS 15
gate, but fail strict code-signature verification and launch on macOS 26. They
are not a valid current-OS continuity anchor. Do not mutate that release;
supersede it with a hardened patch release.

## Consumer verification

For tag `keybay_cli-vX.Y.Z` and a downloaded archive, use GitHub CLI 2.93.0
or newer. Versions through 2.92.0 leaked tokens during these verification
commands ([GHSA-8xvp-7hj6-mcj9](https://github.com/cli/cli/security/advisories/GHSA-8xvp-7hj6-mcj9)):

```sh
gh_version="$(gh --version | awk 'NR == 1 { print $3 }')"
if [[ "$(printf '%s\n' 2.93.0 "$gh_version" | sort -V | head -1)" != 2.93.0 ]]; then
  echo "GitHub CLI 2.93.0 or newer is required" >&2
  exit 1
fi
gh release verify keybay_cli-vX.Y.Z --repo danReynolds/keybay
gh release verify-asset keybay_cli-vX.Y.Z keybay-X.Y.Z-linux-x64.tar.gz \
  --repo danReynolds/keybay
gh attestation verify keybay-X.Y.Z-linux-x64.tar.gz \
  --repo danReynolds/keybay \
  --signer-workflow danReynolds/keybay/.github/workflows/release_cli.yml \
  --source-ref refs/tags/keybay_cli-vX.Y.Z \
  --deny-self-hosted-runners
```

Also check the matching line in `SHA256SUMS`. On macOS, extract the binary and
run strict `codesign` verification plus the online notarization check. Homebrew
uses the archive hashes pinned in its generated formula; pub.dev verifies its
own package archive and OIDC publisher identity.

Hosted runners exercise the no-Dart Linux archive and Homebrew channels. For a
milestone release, repeat the documented quickstart once on clean physical
macOS and Linux accounts; record OS, architecture, installer, and result.
