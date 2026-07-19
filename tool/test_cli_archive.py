#!/usr/bin/env python3
"""Release-archive validation tests, including the no-execution boundary."""

from __future__ import annotations

import io
import pathlib
import shlex
import subprocess
import tarfile
import tempfile


def add_file(
    archive: tarfile.TarFile, name: str, data: bytes = b"x", mode: int = 0o644
) -> None:
    member = tarfile.TarInfo(name)
    member.size = len(data)
    member.mode = mode
    archive.addfile(member, io.BytesIO(data))


def add_directory(archive: tarfile.TarFile, name: str) -> None:
    member = tarfile.TarInfo(name)
    member.type = tarfile.DIRTYPE
    member.mode = 0o755
    archive.addfile(member)


def reject(repo: pathlib.Path, archive: pathlib.Path, case: str) -> None:
    result = subprocess.run(
        ["./tool/verify_cli_archive.sh", str(archive)],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        raise AssertionError(f"unsafe {case} archive passed validation")
    if "invalid release archive:" not in result.stderr:
        raise AssertionError(
            f"unsafe {case} archive failed outside the pre-extraction guard: "
            f"{result.stderr!r}"
        )


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="keybay-archive-negative.") as raw_tmp:
        tmp = pathlib.Path(raw_tmp)

        duplicate = tmp / "duplicate.tar.gz"
        with tarfile.open(duplicate, "w:gz") as archive:
            add_file(archive, "keybay", b"first")
            add_file(archive, "keybay", b"second")
        reject(repo, duplicate, "duplicate-member")

        symlink = tmp / "symlink.tar.gz"
        with tarfile.open(symlink, "w:gz") as archive:
            member = tarfile.TarInfo("keybay")
            member.type = tarfile.SYMTYPE
            member.linkname = "/tmp/keybay-archive-symlink-target"
            archive.addfile(member)
        reject(repo, symlink, "symbolic-link")

        traversal = tmp / "traversal.tar.gz"
        with tarfile.open(traversal, "w:gz") as archive:
            add_file(archive, "../../keybay-archive-escape")
        reject(repo, traversal, "path-traversal")

        unexpected = tmp / "unexpected.tar.gz"
        with tarfile.open(unexpected, "w:gz") as archive:
            add_file(archive, ".hidden")
        reject(repo, unexpected, "unexpected-member")

        missing = tmp / "missing.tar.gz"
        with tarfile.open(missing, "w:gz") as archive:
            add_file(archive, "keybay")
        reject(repo, missing, "missing-member")

        corrupt = tmp / "corrupt.tar.gz"
        corrupt.write_bytes(b"not a gzip archive")
        reject(repo, corrupt, "corrupt")

        sentinel = tmp / "executed"
        valid = tmp / "valid-untrusted.tar.gz"
        with tarfile.open(valid, "w:gz") as archive:
            add_file(archive, "LICENSE")
            add_file(archive, "README.md")
            add_directory(archive, "example")
            add_directory(archive, "example/quickstart")
            for name in ("README.md", "secrets.env.example", "app.sh"):
                data = (repo / "packages/keybay_cli/example/quickstart" / name).read_bytes()
                mode = 0o755 if name == "app.sh" else 0o644
                add_file(archive, f"example/quickstart/{name}", data, mode)
            payload = f"#!/bin/sh\ntouch {shlex.quote(str(sentinel))}\n".encode()
            add_file(archive, "keybay", payload, 0o755)
        result = subprocess.run(
            ["./tool/verify_cli_archive.sh", str(valid)],
            cwd=repo,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(f"valid archive failed validation: {result.stderr!r}")
        if sentinel.exists():
            raise AssertionError("structural archive validation executed the candidate")

    print("CLI release archive guard passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
