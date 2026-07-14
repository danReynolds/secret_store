#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keyway-cli-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

dart compile exe packages/keyway_cli/bin/keyway.dart -o "$tmp/keyway"
dart compile exe packages/keyway_cli/tool/prompt_harness.dart \
  -o "$tmp/prompt_harness"
python3 tool/test_cli_exec.py "$tmp/keyway"
python3 tool/test_cli_pty.py "$tmp/prompt_harness"
python3 tool/test_cli_archive.py
python3 tool/test_homebrew_formula.py
if [[ "$(uname -s)" == "Darwin" ]]; then
  # A local ad-hoc hardened-runtime signature is structurally inspectable but
  # not launchable like the Developer-ID release signature. Keep the executable
  # archive smoke on the original binary; the release workflow executes the
  # packaged Developer-ID binary after signing and notarization.
  cp "$tmp/keyway" "$tmp/keyway-identity"
  codesign --force --sign - --identifier dev.keyway.cli --options runtime \
    "$tmp/keyway-identity"
  KEYWAY_ALLOW_ADHOC=1 ./tool/verify_macos_release.sh "$tmp/keyway-identity"
fi
version="$(awk '$1 == "version:" { print $2 }' packages/keyway_cli/pubspec.yaml)"
archive="$tmp/keyway-$version-test.tar.gz"
./tool/package_cli_release.sh "$tmp/keyway" "$archive"
./tool/verify_cli_archive.sh "$archive" "$version"
if [[ "${KEYWAY_SKIP_DART_INSTALL:-0}" != "1" ]]; then
  ./tool/test_cli_dart_install.sh
fi
