#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -ne 2 ]]; then
  echo "usage: $0 KEYBAY_BINARY OUTPUT.tar.gz" >&2
  exit 2
fi

binary="$1"
output="$2"
if [[ ! -x "$binary" ]]; then
  echo "not an executable Keybay binary: $binary" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keybay-cli-package.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cp "$binary" "$tmp/keybay"
chmod 0755 "$tmp/keybay"
cp packages/keybay_cli/LICENSE "$tmp/LICENSE"
cp packages/keybay_cli/README.md "$tmp/README.md"
mkdir -p "$tmp/example/quickstart"
cp packages/keybay_cli/example/quickstart/README.md \
  "$tmp/example/quickstart/README.md"
cp packages/keybay_cli/example/quickstart/secrets.env.example \
  "$tmp/example/quickstart/secrets.env.example"
cp packages/keybay_cli/example/quickstart/app.sh \
  "$tmp/example/quickstart/app.sh"
chmod 0755 "$tmp/example/quickstart/app.sh"

mkdir -p "$(dirname "$output")"
COPYFILE_DISABLE=1 tar -czf "$output" -C "$tmp" \
  keybay LICENSE README.md example
