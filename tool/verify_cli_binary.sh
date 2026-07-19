#!/usr/bin/env bash
# Runtime checks live separately from archive validation so a packaging job can
# inspect hostile candidate bytes without executing them.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 KEYBAY_BINARY EXPECTED_VERSION" >&2
  exit 2
fi

binary="$1"
version="$2"
if [[ ! -x "$binary" ]]; then
  echo "not an executable Keybay binary: $binary" >&2
  exit 2
fi

actual_version="$("$binary" --version)"
if [[ "$actual_version" != "$version" ]]; then
  echo "release binary version was '$actual_version', expected '$version'" >&2
  exit 1
fi

help="$("$binary" --help)"
for command in run set rm list doctor; do
  if [[ "$help" != *"  $command"* ]]; then
    echo "release binary help omitted command '$command'" >&2
    exit 1
  fi
done
help_lines="$(printf '%s\n' "$help" | wc -l | tr -d ' ')"
if ((help_lines > 24)); then
  echo "release binary help used $help_lines lines, expected at most 24" >&2
  exit 1
fi

echo "CLI release binary passed"
