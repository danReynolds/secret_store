#!/usr/bin/env python3
"""Hermetic checks for the release formula renderer."""

from __future__ import annotations

import hashlib
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


def load_renderer():
    path = pathlib.Path(__file__).with_name("render_homebrew_formula.py")
    spec = importlib.util.spec_from_file_location("render_homebrew_formula", path)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load formula renderer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    renderer = load_renderer()
    version = "0.1.0"
    with tempfile.TemporaryDirectory(prefix="keybay-formula.") as tmp:
        directory = pathlib.Path(tmp)
        expected_hashes = []
        for os_name, arch in renderer.PLATFORMS:
            data = f"{os_name}-{arch}".encode()
            expected_hashes.append(hashlib.sha256(data).hexdigest())
            (directory / renderer.asset(version, os_name, arch)).write_bytes(data)

        formula = renderer.render(version, directory)
        formula_path = directory / "keybay.rb"
        formula_path.write_text(formula, encoding="utf-8")
        for digest in expected_hashes:
            if formula.count(digest) != 1:
                raise AssertionError(f"formula omitted or duplicated {digest}")
        for os_name, arch in renderer.PLATFORMS:
            filename = renderer.asset(version, os_name, arch)
            if formula.count(filename) != 1:
                raise AssertionError(f"formula omitted or duplicated {filename}")
        if 'pkgshare.install "example"' not in formula:
            raise AssertionError("formula did not install the packaged quickstart")
        linux_block = formula.split("  on_linux do\n", 1)[1].split("\n  end", 1)[0]
        if 'depends_on "libsecret"' not in linux_block:
            raise AssertionError("formula did not install Linux's secret-tool client")
        if 'assert_equal "#{version}\\n"' not in formula:
            raise AssertionError("formula test did not verify the CLI version contract")
        subprocess.run(["ruby", "-c", str(formula_path)], check=True)

    print("Homebrew formula renderer passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
