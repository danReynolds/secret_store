#!/usr/bin/env bash
# Hermetic smoke for the current SDK's local `dart install` descriptor. The
# core is still unpublished during development, so the disposable package copy
# points its exact dependency at this checkout. Dart 3.10 supports the final
# hosted spelling but not this newer local descriptor; that SDK is covered by
# the rest of the CLI suite, and its hosted install remains a Phase 3 external
# gate after first publication.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/keybay-dart-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cp -R "$repo/packages/keybay_cli" "$tmp/keybay_cli"
rm -rf "$tmp/keybay_cli/.dart_tool"

awk -v root="$repo" '
  $0 == "  keybay: 0.1.0" {
    print "  keybay:"
    print "    path: " root
    next
  }
  { print }
' "$tmp/keybay_cli/pubspec.yaml" > "$tmp/pubspec.yaml"
mv "$tmp/pubspec.yaml" "$tmp/keybay_cli/pubspec.yaml"

home="$tmp/home"
mkdir -p "$home"
HOME="$home" dart install \
  "keybay_cli@{path: $tmp/keybay_cli}"

installed="$(
  find "$home" \( -type f -o -type l \) \
    -path '*/Dart/install/bin/keybay' -perm -u+x -print -quit
)"
if [[ -z "$installed" ]]; then
  echo "dart install did not create a keybay executable under disposable HOME" >&2
  exit 1
fi
# The installed bundle is a native executable, not a launcher that finds Dart.
actual_version="$(PATH=/usr/bin:/bin "$installed" --version)"
if [[ "$actual_version" != "0.1.0" ]]; then
  echo "installed keybay version was '$actual_version', expected '0.1.0'" >&2
  exit 1
fi
help_lines="$("$installed" --help | wc -l | tr -d ' ')"
if ((help_lines > 24)); then
  echo "installed keybay help used $help_lines lines, expected at most 24" >&2
  exit 1
fi

HOME="$home" dart uninstall keybay_cli
if [[ -e "$installed" ]]; then
  echo "dart uninstall left the keybay executable installed" >&2
  exit 1
fi
echo "CLI hermetic dart install passed"
