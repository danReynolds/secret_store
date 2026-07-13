#!/usr/bin/env python3
"""Render the Homebrew formula from release artifacts and their real hashes."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


PLATFORMS = (
    ("macos", "arm64"),
    ("macos", "x64"),
    ("linux", "arm64"),
    ("linux", "x64"),
)
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def asset(version: str, os_name: str, arch: str) -> str:
    return f"keyway-{version}-{os_name}-{arch}.tar.gz"


def stanza(version: str, directory: pathlib.Path, os_name: str, arch: str) -> str:
    filename = asset(version, os_name, arch)
    path = directory / filename
    if not path.is_file():
        raise FileNotFoundError(f"missing release artifact: {path}")
    url = (
        "https://github.com/danReynolds/keyway/releases/download/"
        f"keyway_cli-v{version}/{filename}"
    )
    return f'      url "{url}"\n      sha256 "{sha256(path)}"'


def render(version: str, directory: pathlib.Path) -> str:
    if not VERSION.fullmatch(version):
        raise ValueError(f"invalid release version: {version!r}")
    values = {
        (os_name, arch): stanza(version, directory, os_name, arch)
        for os_name, arch in PLATFORMS
    }
    return f'''class Keyway < Formula
  desc "Austere, local, run-scoped secret injection"
  homepage "https://github.com/danReynolds/keyway"
  version "{version}"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
{values[("macos", "arm64")]}
    else
{values[("macos", "x64")]}
    end
  end

  on_linux do
    if Hardware::CPU.arm?
{values[("linux", "arm64")]}
    else
{values[("linux", "x64")]}
    end
  end

  def install
    bin.install "keyway"
    prefix.install "README.md"
    pkgshare.install "example"
  end

  test do
    assert_equal "#{{version}}\\n", shell_output("#{{bin}}/keyway --version")
    assert_includes shell_output("#{{bin}}/keyway --help"), "run [-f FILE]"
  end
end
'''


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} VERSION ARTIFACT_DIR OUTPUT", file=sys.stderr)
        return 2
    version = sys.argv[1]
    directory = pathlib.Path(sys.argv[2])
    output = pathlib.Path(sys.argv[3])
    try:
        formula = render(version, directory)
    except (FileNotFoundError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    output.write_text(formula, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
