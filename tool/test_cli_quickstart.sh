#!/usr/bin/env bash
# Runs the documented quickstart against the real fixed-appId product. The
# fixed store is intentionally destructive to an existing Keyway CLI store, so
# this script refuses to run outside an explicitly disposable account/session.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${KEYWAY_QUICKSTART:-}" != "1" ]]; then
  echo "set KEYWAY_QUICKSTART=1 in a disposable account/session" >&2
  exit 2
fi
if [[ "${CI:-}" != "true" && "${KEYWAY_DISPOSABLE_STORE:-}" != "1" ]]; then
  echo "refusing to touch the fixed keyway-cli store outside CI" >&2
  echo "use a disposable account and set KEYWAY_DISPOSABLE_STORE=1" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keyway-cli-quickstart.XXXXXX")"
if [[ "$(uname -s)" == "Darwin" ]]; then
  store_dir="$HOME/Library/Application Support/keyway-cli"
else
  store_dir="${XDG_DATA_HOME:-$HOME/.local/share}/keyway-cli"
fi

if [[ -e "$store_dir" ]]; then
  echo "refusing to overwrite an existing keyway-cli store: $store_dir" >&2
  rm -rf "$tmp"
  exit 2
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
  if security find-generic-password -s keyway-cli -a store-key >/dev/null 2>&1; then
    echo "refusing to overwrite an existing keyway-cli keychain item" >&2
    rm -rf "$tmp"
    exit 2
  fi
elif secret-tool lookup -- service keyway-cli account store-key >/dev/null 2>&1; then
  echo "refusing to overwrite an existing keyway-cli Secret Service item" >&2
  rm -rf "$tmp"
  exit 2
fi

cleanup() {
  rm -rf "$tmp"
  rm -rf "$store_dir"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    security delete-generic-password -s keyway-cli -a store-key >/dev/null 2>&1 || true
  else
    secret-tool clear -- service keyway-cli account store-key >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "${KEYWAY_BINARY:-}" ]]; then
  keyway_binary="$(cd "$(dirname "$KEYWAY_BINARY")" && pwd)/$(basename "$KEYWAY_BINARY")"
  quickstart_dir="${KEYWAY_QUICKSTART_DIR:-packages/keyway_cli/example/quickstart}"
else
  dart compile exe packages/keyway_cli/bin/keyway.dart -o "$tmp/compiled-keyway"
  version="$(awk '$1 == "version:" { print $2 }' packages/keyway_cli/pubspec.yaml)"
  archive="$tmp/keyway-$version-test.tar.gz"
  ./tool/package_cli_release.sh "$tmp/compiled-keyway" "$archive"
  ./tool/verify_cli_archive.sh "$archive" "$version"
  mkdir "$tmp/release"
  tar -xzf "$archive" -C "$tmp/release"
  keyway_binary="$tmp/release/keyway"
  quickstart_dir="$tmp/release/example/quickstart"
fi
python3 tool/test_cli_quickstart.py \
  "$keyway_binary" \
  "$quickstart_dir"
