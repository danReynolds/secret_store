# Keyway CLI release runbook

This is the operational companion to
[cli-implementation-plan.md](cli-implementation-plan.md) Phase 3. A release is
not complete merely because a tag exists: every receipt below is part of the
security and installation contract.

## One-time owner setup

1. Protect `main` before adding release credentials:

   - require changes to arrive through a pull request;
   - require the branch to be current and require every top-level job in the
     ordinary `ci` workflow: both `analyze-and-test` matrix legs,
     `cli-minimum-sdk`, `integration-macos`, `integration-linux`,
     `supply-chain`, and `crypto-pin-canary`;
   - require conversation resolution and signed commits; and
   - disallow force pushes and branch deletion, including for administrators.

   This is a single-maintainer repository, so do not require an approving
   review that its owner cannot provide on their own pull request. The two
   deployment environments below remain separately approval-gated. In
   **Settings → Actions → General**, also enable **Require actions to be
   pinned to a full-length commit SHA**. The workflows already use full SHAs;
   this setting prevents a future regression.

2. Create the protected GitHub environment `release` and require approval for
   it. Add these environment secrets:

   - `APPLE_CERTIFICATE_P12_BASE64`
   - `APPLE_CERTIFICATE_PASSWORD`
   - `APPLE_SIGNING_IDENTITY`
   - `APPLE_TEAM_ID` — the frozen 10-character Team ID; keep this independent
     of the certificate secret so the verifier rejects an accidental team swap
   - `APPLE_NOTARY_KEY_P8_BASE64`
   - `APPLE_NOTARY_KEY_ID`
   - `APPLE_NOTARY_ISSUER_ID`
   - `HOMEBREW_TAP_TOKEN` — a fine-grained token with Contents write access to
     `danReynolds/homebrew-tap` only

3. Create the public `danReynolds/homebrew-tap` repository with a `main`
   branch and a `Formula/` directory. The release workflow refuses to publish
   before it can read this repository; after the GitHub release exists it
   writes only `Formula/keyway.rb`. Treat the tap as a code-distribution trust
   root: keep it formula-only apart from a short README, add no collaborators,
   require linear history, and disallow force pushes and branch deletion. The
   fine-grained `HOMEBREW_TAP_TOKEN` is its only automated writer and has no
   access to the Keyway source repository. A pull-request-only rule is not used
   on the tap because the approval-gated release job deliberately commits the
   generated, hash-pinned formula directly; the fresh Homebrew acceptance job
   then installs and exercises that public commit before pub.dev publication.
4. Create the protected GitHub environment `pub.dev` and require approval.
   Push the signed core tag first:

   ```sh
   git tag -s v0.1.0 -m "keyway 0.1.0"
   git push origin v0.1.0
   ```

   The bootstrap guard in `publish.yml` validates the signed tag and exact
   archive but deliberately skips OIDC because pub.dev does not permit
   automated first publication. After that workflow succeeds, check out the
   exact tag in a clean checkout and publish the core manually:

   ```sh
   git checkout --detach v0.1.0
   ./tool/validate_publish.sh . cryptography ffi
   core_stage="$(mktemp -d)"
   rmdir "$core_stage"
   ./tool/stage_core_publish.sh "$core_stage"
   (cd "$core_stage" && dart pub publish)
   rm -rf "$core_stage"
   ```

   Review the archive before confirming. Then enable GitHub trusted publishing
   for `keyway` from `danReynolds/keyway`, workflow `publish.yml`, tag pattern
   `v{{version}}`, requiring the `pub.dev` environment. Remove the two explicit
   `v0.1.0` bootstrap conditions from `publish.yml`; later core releases use
   OIDC exclusively. Do not publish `keyway_cli` yet: its first manual
   publication occurs only after the signed native release in the section
   below, because it exact-pins this now-hosted core version.
5. Resolve Appendix B's updated trademark and same-category naming review
   before signing the first release. The repository-hosted GitHub Pages site is
   the documentation surface; do not add a custom domain, separate GitHub
   organization, or placeholder packages on unused registries for v0.1.

## macOS identity and notarization

Every release binary is independently checked for:

- identifier `dev.keyway.cli`;
- Developer ID Application authority and a secure timestamp;
- hardened-runtime flag;
- no entitlements;
- a designated requirement anchored to Apple, the frozen identifier, and the
  signing team;
- successful access to a store created by a separately compiled binary with
  the same designated identity;
- an accepted notarization with an empty notary issue list; and
- successful `spctl --assess --type execute` verification.

Apple creates notarization tickets for standalone Mach-O binaries but does not
support stapling tickets to them. The workflow therefore submits a ZIP,
publishes Apple's online ticket for the binary, and distributes the unchanged
signed/notarized binary in a tarball. It does not add a `.pkg`, disk image, or
app bundle solely to gain stapling. The owner ratified this standalone contract
on 2026-07-13; offline-first installer distribution is not a v1 requirement.

## Cut a CLI release

1. Confirm the candidate commit is on `main`, ordinary CI is green on macOS
   and Linux, `packages/keyway_cli/pubspec.yaml` and `CHANGELOG.md` carry the
   release version, and the CLI's exact `keyway` pin names an already-published
   core version. The release tag must be signed by a key GitHub recognizes as
   verified; the workflow rejects lightweight or unverified tags.
2. From a clean checkout:

   ```sh
   ./tool/test.sh
   ./tool/test_linux.sh
   ./tool/validate_publish.sh . cryptography ffi
   ./tool/validate_publish.sh packages/keyway_cli ffi keyway
   ```

   The validator permits only pub's expected warnings for the normative exact
   pins (`cryptography` and `ffi` in the core; `ffi` and `keyway` in the CLI).
   For the core, it builds and validates the same clean-checkout staging form
   used by automated publishing: an explicit package allowlist with no CLI
   sources or repository-only workspace metadata. The CLI is validated from
   its workspace directory, proving that both archives remain independently
   publishable.
   Validation errors, dirty package files, or any new warning fail the release.

3. Tag the exact reviewed commit with the package-specific tag:

   ```sh
   git tag -s keyway_cli-v0.1.0 -m "keyway_cli 0.1.0"
   git push origin keyway_cli-v0.1.0
   ```

4. The release workflow rejects a version mismatch or a tag not contained in
   `origin/main`. It then builds native arm64/x64 artifacts on each OS, signs
   and notarizes macOS, executes the real README quickstart, verifies archive
   contents, publishes SHA-256 sums and GitHub provenance attestations, creates
   the GitHub release, and updates the tap formula from the actual artifact
   hashes. Fresh runners then install the published Homebrew formula and Linux
   archive without setting up Dart, verify the Linux checksum and provenance,
   and execute the packaged quickstart against real platform stores. Only those
   jobs can unlock pub.dev. For v0.1.0, the explicit bootstrap guard validates
   the CLI package but skips OIDC, ensuring the first manual publication cannot
   precede the native release. A native-release or channel-acceptance failure
   therefore cannot publish a partial CLI release.
5. Inspect the workflow logs, the per-architecture Apple notary result and
   issue-log artifacts, release attestations, checksums, and tap commit. A
   skipped architecture or failed post-release formula update is an incomplete
   release, not a warning.
6. After every native v0.1.0 receipt passes, check out the exact signed tag in a
   clean checkout and publish the CLI's first version manually:

   ```sh
   git checkout --detach keyway_cli-v0.1.0
   ./tool/validate_publish.sh packages/keyway_cli ffi keyway
   dart pub -C packages/keyway_cli publish
   ```

   Review the archive before confirming. Then enable GitHub trusted publishing
   for `keyway_cli` from `danReynolds/keyway`, workflow `release_cli.yml`, tag
   pattern `keyway_cli-v{{version}}`, requiring the `pub.dev` environment.
   Remove the two explicit `keyway_cli-v0.1.0` bootstrap conditions from
   `release_cli.yml`; later CLI releases publish through OIDC only. The first
   release is not complete until this manual publication and the hosted-install
   receipt below succeed.

## Clean-machine acceptance

The release workflow automatically exercises the published Homebrew and Linux
archive channels on fresh runners without setting up Dart. Complete the same
acceptance once in fresh macOS and Ubuntu user accounts with no Dart installation
and no existing `keyway-cli` store; those physical receipts catch image-specific
assumptions that hosted runners cannot.

### Homebrew on macOS

```sh
brew install danreynolds/tap/keyway
keyway --version
keyway doctor
cd "$(brew --prefix keyway)/share/keyway/example/quickstart"
cp secrets.env.example .secrets.env
keyway run -- ./app.sh
keyway set acme-example/openai-api-key
keyway run -- ./app.sh
keyway rm acme-example/openai-api-key
```

The first `run` must exit 78 and print the exact `set` remediation without
launching the child. Input at `set` must be hidden. The second `run` must show
the literal URL and report the secret as available without printing its value.

### GitHub archive on Linux

Install the distro's `secret-tool` client (`libsecret-tools` on Debian/Ubuntu)
and use an unlocked desktop Secret Service provider. Verify `SHA256SUMS` and
the GitHub attestation, extract the matching Linux archive, place `keyway` on
`PATH`, then run the same commands from the archive's `example/quickstart`
directory. `doctor` must identify Secret Service as reachable and unlocked.

### Dart-native channel

From a separate clean account with Dart 3.10 or newer:

```sh
dart install keyway_cli
keyway --version
keyway doctor
```

Download the matching release's source archive and run the same quickstart
from `packages/keyway_cli/example/quickstart`; confirm `doctor` reports the
actual compiled/VM trust unit. This channel is accepted only after
installation resolves solely from pub.dev; a workspace or path override is
not evidence.

Record the OS image, architecture, install command, elapsed onboarding time,
and command receipts for each lane. Phase 3 closes only when both no-Dart lanes
onboard in under five minutes and the Dart-native lane resolves cleanly.
