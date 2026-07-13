#!/usr/bin/env bash
# Pub warns about exact dependency constraints. Those pins are a deliberate
# supply-chain contract, so accept exactly the named warnings while still
# failing on validation errors, dirty package files, or any new warning.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ $# -lt 2 ]]; then
  echo "usage: $0 PACKAGE_DIRECTORY EXACT_PIN_DEPENDENCY [...]" >&2
  exit 2
fi

package_directory="$1"
shift
expected_warning_count="$#"
output="$(mktemp "${TMPDIR:-/tmp}/keyway-publish.XXXXXX")"
core_stage=""
cleanup() {
  rm -f "$output"
  if [[ -n "$core_stage" ]]; then
    rm -rf "$core_stage"
  fi
}
trap cleanup EXIT

if [[ "$package_directory" == "." ]]; then
  core_stage="$(mktemp -d "${TMPDIR:-/tmp}/keyway-core-publish.XXXXXX")"
  rmdir "$core_stage"
  ./tool/stage_core_publish.sh "$core_stage"
  package_directory="$core_stage"
fi

dart pub -C "$package_directory" publish --dry-run --ignore-warnings \
  2>&1 | tee "$output"

warning_count="$(grep -c '^\* ' "$output" || true)"
if [[ "$warning_count" != "$expected_warning_count" ]]; then
  echo "publish validation reported $warning_count warnings, expected $expected_warning_count exact-pin warnings" >&2
  exit 1
fi
for dependency in "$@"; do
  expected="* Your dependency on \"$dependency\" should allow more than one version. For example:"
  if ! grep -Fxq "$expected" "$output"; then
    echo "publish validation omitted the expected $dependency exact-pin warning" >&2
    exit 1
  fi
done

warning_noun="warnings"
if [[ "$expected_warning_count" == "1" ]]; then
  warning_noun="warning"
fi
if ! grep -Fxq "Package has $expected_warning_count $warning_noun." "$output"; then
  echo "publish validation warning summary changed unexpectedly" >&2
  exit 1
fi

echo "Publish archive passed with only the intentional exact-pin warnings"
