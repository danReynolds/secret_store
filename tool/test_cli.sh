#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keybay-cli-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
repo="$PWD"

# The source runner must ignore a caller package config and keep the caller's
# directory as the manifest boundary.
mkdir -p "$tmp/dev-project/.dart_tool"
printf '{"configVersion":2,"packages":[]}\n' > \
  "$tmp/dev-project/.dart_tool/package_config.json"
printf 'KEYBAY_DEV_MARKER=from-example\n' > \
  "$tmp/dev-project/.secrets.env"
dev_output="$(
  cd "$tmp/dev-project"
  "$repo/tool/keybay-dev" run -- /usr/bin/printenv KEYBAY_DEV_MARKER
)"
[[ "$dev_output" == "from-example" ]] || {
  echo "keybay-dev did not preserve the caller manifest directory" >&2
  exit 1
}

dart compile exe packages/keybay_cli/bin/keybay.dart -o "$tmp/keybay"
dart compile exe packages/keybay_cli/tool/prompt_harness.dart \
  -o "$tmp/prompt_harness"
python3 tool/test_cli_exec.py "$tmp/keybay"
python3 tool/test_cli_pty.py "$tmp/prompt_harness"
python3 tool/test_cli_archive.py
python3 tool/test_homebrew_formula.py
if [[ "$(uname -s)" == "Darwin" ]]; then
  # A local ad-hoc hardened-runtime signature is structurally inspectable but
  # not launchable like the Developer-ID release signature. Keep the executable
  # archive smoke on the original binary; the release workflow executes the
  # packaged Developer-ID binary after signing and notarization.
  cp "$tmp/keybay" "$tmp/keybay-identity"
  codesign --force --sign - --identifier io.github.danreynolds.keybay.cli --options runtime \
    "$tmp/keybay-identity"
  KEYBAY_ALLOW_ADHOC=1 ./tool/verify_macos_release.sh "$tmp/keybay-identity"
fi
version="$(awk '$1 == "version:" { print $2 }' packages/keybay_cli/pubspec.yaml)"
archive="$tmp/keybay-$version-test.tar.gz"
./tool/package_cli_release.sh "$tmp/keybay" "$archive"
./tool/verify_cli_archive.sh "$archive" "$version"
if [[ "${KEYBAY_SKIP_DART_INSTALL:-0}" != "1" ]]; then
  ./tool/test_cli_dart_install.sh
fi
