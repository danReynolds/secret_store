#!/usr/bin/env python3
"""PTY checks for Keybay's hidden prompt and signal restoration."""

from __future__ import annotations

import errno
import os
import pty
import select
import signal
import sys
import termios
import time


PROMPT = b"Value for test/prompt (input hidden): "
SECRET = b"pty-secret-sentinel"
TIMEOUT = 8.0


def echo_enabled(fd: int) -> bool:
    return bool(termios.tcgetattr(fd)[3] & termios.ECHO)


def wait_for(fd: int, needle: bytes, timeout: float = TIMEOUT) -> bytes:
    deadline = time.monotonic() + timeout
    output = bytearray()
    while needle not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out waiting for {needle!r}: {bytes(output)!r}")
        readable, _, _ = select.select([fd], [], [], remaining)
        if not readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
    if needle not in output:
        raise AssertionError(f"process ended before {needle!r}: {bytes(output)!r}")
    return bytes(output)


def read_remaining(fd: int, timeout: float = 1.0) -> bytes:
    deadline = time.monotonic() + timeout
    output = bytearray()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.05)
        if not readable:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
    return bytes(output)


def spawn(executable: str, *arguments: str) -> tuple[int, int, bytes]:
    pid, master = pty.fork()
    if pid == 0:
        os.execl(executable, executable, *arguments)
    output = wait_for(master, PROMPT)
    if echo_enabled(master):
        raise AssertionError("terminal echo remained enabled after the prompt")
    return pid, master, output


def wait_exit(pid: int, expected: int) -> None:
    _, status = os.waitpid(pid, 0)
    actual = os.waitstatus_to_exitcode(status)
    if actual != expected:
        raise AssertionError(f"exit status {actual}, expected {expected}")


def wait_for_echo(fd: int, enabled: bool, timeout: float = TIMEOUT) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if echo_enabled(fd) is enabled:
            return
        time.sleep(0.01)
    raise AssertionError(f"terminal echo did not become {enabled}")


def check_normal(executable: str) -> None:
    pid, master, output = spawn(executable)
    os.write(master, SECRET + b"\n")
    output += wait_for(master, f"read:{len(SECRET)}".encode())
    wait_for_echo(master, True)
    wait_exit(pid, 0)
    output += read_remaining(master)
    if SECRET in output:
        raise AssertionError("hidden input appeared in PTY output")
    os.close(master)


def check_disposition_restoration(executable: str) -> None:
    pid, master, output = spawn(executable, "--verify-dispositions")
    os.write(master, SECRET + b"\n")
    output += wait_for(master, b"signals:restored")
    wait_for_echo(master, True)
    wait_exit(pid, 0)
    output += read_remaining(master)
    if SECRET in output:
        raise AssertionError("hidden input appeared during disposition check")
    os.close(master)


def check_termination(executable: str, sig: signal.Signals, status: int) -> None:
    pid, master, output = spawn(executable)
    os.kill(pid, sig)
    wait_for_echo(master, True)
    wait_exit(pid, status)
    output += read_remaining(master)
    if SECRET in output:
        raise AssertionError(f"secret appeared after {sig.name}")
    os.close(master)


def check_suspend_is_fail_safe(executable: str) -> None:
    pid, master, output = spawn(executable)
    os.kill(pid, signal.SIGTSTP)
    time.sleep(0.05)
    waited_pid, _ = os.waitpid(pid, os.WNOHANG)
    if waited_pid != 0:
        raise AssertionError("SIGTSTP terminated the process with echo hidden")
    if echo_enabled(master):
        raise AssertionError("SIGTSTP unexpectedly changed prompt echo state")
    os.write(master, SECRET + b"\n")
    output += wait_for(master, f"read:{len(SECRET)}".encode())
    wait_for_echo(master, True)
    wait_exit(pid, 0)
    output += read_remaining(master)
    if SECRET in output:
        raise AssertionError("hidden input appeared after SIGTSTP")
    os.close(master)


def check_quit_is_fail_safe(executable: str) -> None:
    pid, master, output = spawn(executable)
    os.kill(pid, signal.SIGQUIT)
    time.sleep(0.05)
    waited_pid, _ = os.waitpid(pid, os.WNOHANG)
    if waited_pid != 0:
        raise AssertionError("SIGQUIT terminated the process with echo hidden")
    if echo_enabled(master):
        raise AssertionError("SIGQUIT unexpectedly changed prompt echo state")
    os.write(master, SECRET + b"\n")
    output += wait_for(master, f"read:{len(SECRET)}".encode())
    wait_for_echo(master, True)
    wait_exit(pid, 0)
    output += read_remaining(master)
    if SECRET in output:
        raise AssertionError("hidden input appeared after SIGQUIT")
    os.close(master)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} PROMPT_HARNESS", file=sys.stderr)
        return 2
    executable = os.path.abspath(sys.argv[1])
    check_normal(executable)
    check_disposition_restoration(executable)
    for sig, status in (
        (signal.SIGINT, 130),
        (signal.SIGTERM, 143),
        (signal.SIGHUP, 129),
    ):
        check_termination(executable, sig, status)
    check_quit_is_fail_safe(executable)
    check_suspend_is_fail_safe(executable)
    print("PTY prompt checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
