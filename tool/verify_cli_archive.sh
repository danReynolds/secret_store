#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ARCHIVE.tar.gz EXPECTED_VERSION" >&2
  exit 2
fi

archive="$1"
version="$2"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/keyway-cli-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Validate the complete archive structure before extraction. Besides making the
# release contract exact, this prevents a link or duplicate member from
# redirecting a later member outside the temporary directory.
python3 - "$archive" <<'PY'
import sys
import tarfile

expected = {
    "LICENSE": "file",
    "README.md": "file",
    "example": "directory",
    "example/quickstart": "directory",
    "example/quickstart/README.md": "file",
    "example/quickstart/secrets.env.example": "file",
    "example/quickstart/verify.sh": "file",
    "keyway": "file",
}

try:
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        seen = set()
        for member in archive.getmembers():
            if member.name in seen:
                raise ValueError(f"duplicate member {member.name!r}")
            seen.add(member.name)
            wanted = expected.get(member.name)
            if wanted is None:
                raise ValueError(f"unexpected member {member.name!r}")
            actual = "file" if member.isfile() else "directory" if member.isdir() else "unsafe"
            if actual != wanted:
                raise ValueError(
                    f"member {member.name!r} was {actual}, expected {wanted}"
                )
        missing = sorted(set(expected) - seen)
        if missing:
            raise ValueError(f"missing members {missing!r}")
except (OSError, tarfile.TarError, ValueError) as error:
    print(f"invalid release archive: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
tar -xzf "$archive" -C "$tmp"
expected_files=$'LICENSE\nREADME.md\nexample/quickstart/README.md\nexample/quickstart/secrets.env.example\nexample/quickstart/verify.sh\nkeyway'
actual_files="$(cd "$tmp" && find . -type f -print | sed 's#^\./##' | sort)"
if [[ "$actual_files" != "$expected_files" ]]; then
  echo "unexpected release archive files:" >&2
  printf '%s\n' "$actual_files" >&2
  exit 1
fi
expected_dirs=$'example\nexample/quickstart'
actual_dirs="$(cd "$tmp" && find . -mindepth 1 -type d -print | sed 's#^\./##' | sort)"
if [[ "$actual_dirs" != "$expected_dirs" ]]; then
  echo "unexpected release archive directories:" >&2
  printf '%s\n' "$actual_dirs" >&2
  exit 1
fi
if find "$tmp" -type l -print -quit | grep -q .; then
  echo "release archive unexpectedly contains a symbolic link" >&2
  exit 1
fi

if [[ ! -x "$tmp/keyway" ]]; then
  echo "release archive keyway binary is not executable" >&2
  exit 1
fi
if [[ ! -x "$tmp/example/quickstart/verify.sh" ]]; then
  echo "release archive quickstart verifier is not executable" >&2
  exit 1
fi
for relative in \
  example/quickstart/README.md \
  example/quickstart/secrets.env.example \
  example/quickstart/verify.sh; do
  if ! cmp -s "$tmp/$relative" "packages/keyway_cli/$relative"; then
    echo "release archive changed packaged example file '$relative'" >&2
    exit 1
  fi
done
actual_version="$("$tmp/keyway" --version)"
if [[ "$actual_version" != "$version" ]]; then
  echo "release binary version was '$actual_version', expected '$version'" >&2
  exit 1
fi

help="$("$tmp/keyway" --help)"
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

echo "CLI release archive passed"
