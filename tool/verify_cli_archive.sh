#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 ARCHIVE.tar.gz" >&2
  exit 2
fi

archive="$1"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/keybay-cli-verify.XXXXXX")"
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
    "example/quickstart/app.sh": "file",
    "keybay": "file",
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
expected_files=$'LICENSE\nREADME.md\nexample/quickstart/README.md\nexample/quickstart/app.sh\nexample/quickstart/secrets.env.example\nkeybay'
actual_files="$(cd "$tmp" && find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)"
if [[ "$actual_files" != "$expected_files" ]]; then
  echo "unexpected release archive files:" >&2
  printf '%s\n' "$actual_files" >&2
  exit 1
fi
expected_dirs=$'example\nexample/quickstart'
actual_dirs="$(cd "$tmp" && find . -mindepth 1 -type d -print | sed 's#^\./##' | LC_ALL=C sort)"
if [[ "$actual_dirs" != "$expected_dirs" ]]; then
  echo "unexpected release archive directories:" >&2
  printf '%s\n' "$actual_dirs" >&2
  exit 1
fi
if find "$tmp" -type l -print -quit | grep -q .; then
  echo "release archive unexpectedly contains a symbolic link" >&2
  exit 1
fi

if [[ ! -x "$tmp/keybay" ]]; then
  echo "release archive keybay binary is not executable" >&2
  exit 1
fi
if [[ ! -x "$tmp/example/quickstart/app.sh" ]]; then
  echo "release archive quickstart verifier is not executable" >&2
  exit 1
fi
for relative in \
  example/quickstart/README.md \
  example/quickstart/secrets.env.example \
  example/quickstart/app.sh; do
  if ! cmp -s "$tmp/$relative" "packages/keybay_cli/$relative"; then
    echo "release archive changed packaged example file '$relative'" >&2
    exit 1
  fi
done
echo "CLI release archive passed"
