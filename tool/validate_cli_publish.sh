#!/usr/bin/env bash
# Pub warns about exact dependency constraints. Those pins are a deliberate
# release and supply-chain contract, so accept exactly those warnings while
# still failing on validation errors or any newly introduced warning.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

output="$(mktemp "${TMPDIR:-/tmp}/keyway-cli-publish.XXXXXX")"
trap 'rm -f "$output"' EXIT

dart pub -C packages/keyway_cli publish --dry-run --ignore-warnings \
  2>&1 | tee "$output"

warning_count="$(grep -c '^\* ' "$output" || true)"
if [[ "$warning_count" != "2" ]]; then
  echo "publish validation reported $warning_count warnings, expected 2 exact-pin warnings" >&2
  exit 1
fi
for dependency in ffi keyway; do
  expected="* Your dependency on \"$dependency\" should allow more than one version. For example:"
  if ! grep -Fxq "$expected" "$output"; then
    echo "publish validation omitted the expected $dependency exact-pin warning" >&2
    exit 1
  fi
done
if ! grep -Fxq 'Package has 2 warnings.' "$output"; then
  echo "publish validation warning summary changed unexpectedly" >&2
  exit 1
fi

echo "CLI publish archive passed with only the two intentional exact-pin warnings"
