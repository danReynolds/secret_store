#!/usr/bin/env bash
# Runs the documented quickstart against the real fixed-appId product. The
# fixed store is intentionally destructive to an existing Keybay CLI store, so
# this script refuses to run outside an explicitly disposable account/session.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${KEYBAY_QUICKSTART:-}" != "1" ]]; then
  echo "set KEYBAY_QUICKSTART=1 in a disposable account/session" >&2
  exit 2
fi
if [[ "${CI:-}" != "true" && "${KEYBAY_DISPOSABLE_STORE:-}" != "1" ]]; then
  echo "refusing to touch the fixed keybay-cli store outside CI" >&2
  echo "use a disposable account and set KEYBAY_DISPOSABLE_STORE=1" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keybay-cli-quickstart.XXXXXX")"
if [[ "$(uname -s)" == "Darwin" ]]; then
  store_dir="$HOME/Library/Application Support/keybay-cli"
else
  store_dir="${XDG_DATA_HOME:-$HOME/.local/share}/keybay-cli"
fi

if [[ -e "$store_dir" ]]; then
  echo "refusing to overwrite an existing keybay-cli store: $store_dir" >&2
  rm -rf "$tmp"
  exit 2
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
  if security find-generic-password -s keybay-cli -a store-key >/dev/null 2>&1; then
    echo "refusing to overwrite an existing keybay-cli keychain item" >&2
    rm -rf "$tmp"
    exit 2
  fi
elif secret-tool lookup -- service keybay-cli account store-key >/dev/null 2>&1; then
  echo "refusing to overwrite an existing keybay-cli Secret Service item" >&2
  rm -rf "$tmp"
  exit 2
fi

cleanup() {
  rm -rf "$tmp"
  rm -rf "$store_dir"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    security delete-generic-password -s keybay-cli -a store-key >/dev/null 2>&1 || true
  else
    secret-tool clear -- service keybay-cli account store-key >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "${KEYBAY_BINARY:-}" ]]; then
  keybay_binary="$(cd "$(dirname "$KEYBAY_BINARY")" && pwd)/$(basename "$KEYBAY_BINARY")"
  quickstart_dir="${KEYBAY_QUICKSTART_DIR:-packages/keybay_cli/example/quickstart}"
else
  dart compile exe packages/keybay_cli/bin/keybay.dart -o "$tmp/compiled-keybay"
  version="$(awk '$1 == "version:" { print $2 }' packages/keybay_cli/pubspec.yaml)"
  archive="$tmp/keybay-$version-test.tar.gz"
  ./tool/package_cli_release.sh "$tmp/compiled-keybay" "$archive"
  ./tool/verify_cli_archive.sh "$archive" "$version"
  mkdir "$tmp/release"
  tar -xzf "$archive" -C "$tmp/release"
  keybay_binary="$tmp/release/keybay"
  quickstart_dir="$tmp/release/example/quickstart"
fi
python3 tool/test_cli_quickstart.py \
  "$keybay_binary" \
  "$quickstart_dir"
