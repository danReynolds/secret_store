#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -ne 2 ]]; then
  echo "usage: $0 KEYWAY_BINARY OUTPUT.tar.gz" >&2
  exit 2
fi

binary="$1"
output="$2"
if [[ ! -x "$binary" ]]; then
  echo "not an executable Keyway binary: $binary" >&2
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/keyway-cli-package.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cp "$binary" "$tmp/keyway"
chmod 0755 "$tmp/keyway"
cp packages/keyway_cli/LICENSE "$tmp/LICENSE"
cp packages/keyway_cli/README.md "$tmp/README.md"
mkdir -p "$tmp/example/quickstart"
cp packages/keyway_cli/example/quickstart/README.md \
  "$tmp/example/quickstart/README.md"
cp packages/keyway_cli/example/quickstart/secrets.env.example \
  "$tmp/example/quickstart/secrets.env.example"
cp packages/keyway_cli/example/quickstart/verify.sh \
  "$tmp/example/quickstart/verify.sh"
chmod 0755 "$tmp/example/quickstart/verify.sh"

mkdir -p "$(dirname "$output")"
COPYFILE_DISABLE=1 tar -czf "$output" -C "$tmp" \
  keyway LICENSE README.md example
