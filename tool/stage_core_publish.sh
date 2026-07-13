#!/usr/bin/env bash
# Build the publishable core package without embedding the CLI workspace
# member. Dart applies a workspace root's `.pubignore` to its members, so the
# root cannot exclude `packages/` directly without emptying keyway_cli's
# archive. Instead, publish the core from this exact, auditable allowlist and
# remove repository-only workspace metadata from the staged pubspec.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

if [[ $# != 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  exit 2
fi

output="$1"
if [[ -e "$output" ]]; then
  echo "core publish output already exists: $output" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "core publish staging requires a clean checkout" >&2
  exit 1
fi

mkdir -p "$output"
git archive --format=tar HEAD -- \
  .pubignore \
  CHANGELOG.md \
  LICENSE \
  README.md \
  SECURITY.md \
  analysis_options.yaml \
  dart_test.yaml \
  pubspec.yaml \
  doc \
  example \
  lib \
  test \
  | tar -xf - -C "$output"

awk '
  BEGIN { skip = 0 }
  /^workspace:$/ { skip = 1; next }
  skip && /^  - / { next }
  skip { skip = 0 }
  { print }
' "$output/pubspec.yaml" > "$output/pubspec.yaml.staged"
mv "$output/pubspec.yaml.staged" "$output/pubspec.yaml"

if grep -Eq '^(workspace:|resolution:[[:space:]]+workspace)' \
  "$output/pubspec.yaml"; then
  echo "staged core pubspec retained workspace-only metadata" >&2
  exit 1
fi
if [[ -e "$output/packages" ]]; then
  echo "staged core package contains a workspace member" >&2
  exit 1
fi

echo "Staged core package at $output"
