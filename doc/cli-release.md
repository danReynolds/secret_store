# Keyway CLI release runbook

This is the operational companion to
[cli-implementation-plan.md](cli-implementation-plan.md) Phase 3. A release is
not complete merely because a tag exists: every receipt below is part of the
security and installation contract.

## One-time owner setup

1. Create the protected GitHub environment `release` and require approval for
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

2. Create the public `danReynolds/homebrew-tap` repository with a `main`
   branch and a `Formula/` directory. The release workflow refuses to publish
   before it can read this repository; after the GitHub release exists it
   writes only `Formula/keyway.rb`.
3. Manually publish the first packages in dependency order. Pub.dev does not
   permit automated publishing until a package already exists:

   ```sh
   core_stage="$(mktemp -d)"
   rmdir "$core_stage"
   ./tool/stage_core_publish.sh "$core_stage"
   (cd "$core_stage" && dart pub publish)
   rm -rf "$core_stage"
   dart pub -C packages/keyway_cli publish
   ```

   Review each archive before confirming. Publish `keyway` first because
   `keyway_cli` exact-pins it. Then enable GitHub trusted publishing for
   `danReynolds/keyway`: `publish.yml` with tag pattern `v{{version}}` for the
   core, and `release_cli.yml` with tag pattern
   `keyway_cli-v{{version}}` for the CLI. Both use the protected `pub.dev`
   environment. Both automated paths require a signed, GitHub-verified tag on
   `main` whose version matches the package before requesting an OIDC token.
4. Complete Appendix B's owner actions: register `keyway.dev`, reserve the
   GitHub organization if available, create the scoped npm fallback, file the
   npm/PyPI reclamations, and record the trademark sanity check.

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
app bundle solely to gain stapling. The normative implementation plan still
says "staple" and must be ratified to this technically possible contract
before the first tag.

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
   the GitHub release, updates the tap formula from the actual artifact hashes,
   and only then publishes the CLI through pub.dev trusted publishing. A
   native-release failure therefore cannot publish a partial CLI release.
5. Inspect the workflow logs, the per-architecture Apple notary result and
   issue-log artifacts, release attestations, checksums, and tap commit. A
   skipped architecture or failed post-release formula update is an incomplete
   release, not a warning.

## Clean-machine acceptance

Use fresh macOS and Ubuntu accounts with no Dart installation and no existing
`keyway-cli` store.

### Homebrew on macOS

```sh
brew install danreynolds/tap/keyway
keyway --version
keyway doctor
cd "$(brew --prefix keyway)/share/keyway/example/quickstart"
cp secrets.env.example .secrets.env
keyway run -- ./verify.sh
keyway set acme-example/openai-api-key
keyway run -- ./verify.sh
keyway rm acme-example/openai-api-key
```

The first `run` must exit 78 and print the exact `set` remediation without
launching the child. Input at `set` must be hidden. The second `run` must print
only `Keyway quickstart passed.`

### GitHub archive on Linux

Verify `SHA256SUMS` and the GitHub attestation, extract the matching Linux
archive, place `keyway` on `PATH`, then run the same commands from the
archive's `example/quickstart` directory. `doctor` must identify Secret
Service as reachable and unlocked.

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
