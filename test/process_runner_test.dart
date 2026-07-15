@Tags(['unit'])
@TestOn('mac-os || linux')
library;

// Drives the REAL SystemProcessRunner against actual subprocesses. The rest of
// the suite exercises SecretToolApi over a scripted fake runner, so the
// load-bearing runner behaviors — timeout SIGKILL, the timer being armed before
// a stdin write that can block, broken-pipe swallowing, launch-failure mapping —
// were otherwise untested. These use only `sh`/`cat`/`sleep`, coreutils as
// available on the macOS+Linux runners as the `chmod` other unit tests shell
// out to.

import 'dart:convert';

import 'package:keybay/src/ffi/process_runner.dart';
import 'package:test/test.dart';

void main() {
  const runner = SystemProcessRunner();
  const ok = Duration(seconds: 10);

  test('captures stdout on a clean exit', () async {
    final r = await runner.run('sh', ['-c', 'printf hello'], timeout: ok);
    expect(r.launchFailed, isFalse);
    expect(r.timedOut, isFalse);
    expect(r.exitCode, 0);
    expect(utf8.decode(r.stdout), 'hello');
  });

  test('pipes stdin through to the child (cat echoes it back)', () async {
    final r =
        await runner.run('cat', const [], stdin: 'piped-secret', timeout: ok);
    expect(r.exitCode, 0);
    expect(utf8.decode(r.stdout), 'piped-secret');
  });

  test('keeps stdout and stderr separate', () async {
    final r = await runner.run('sh', ['-c', 'printf out; printf err 1>&2'],
        timeout: ok);
    expect(r.exitCode, 0);
    expect(utf8.decode(r.stdout), 'out');
    expect(utf8.decode(r.stderr), 'err');
  });

  test('propagates a nonzero exit code', () async {
    final r = await runner.run('sh', ['-c', 'exit 3'], timeout: ok);
    expect(r.launchFailed, isFalse);
    expect(r.timedOut, isFalse);
    expect(r.exitCode, 3);
  });

  test('a missing executable is launchFailed, never a throw', () async {
    final r =
        await runner.run('keybay_no_such_binary_xyz', const [], timeout: ok);
    expect(r.launchFailed, isTrue);
    expect(r.exitCode, -1);
  });

  test('a slow child is SIGKILLed at the timeout (never hangs)', () async {
    final sw = Stopwatch()..start();
    final r = await runner.run('sleep', ['30'],
        timeout: const Duration(milliseconds: 300));
    sw.stop();
    expect(r.timedOut, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'must return at the timeout, not wait out sleep 30');
  });

  test(
      'a child that never drains a large stdin still times out '
      '(the timer is armed before the blocking flush)', () async {
    // >64 KiB so proc.stdin.flush() blocks on the OS pipe buffer against a child
    // that never reads it. The regression this guards: arming the timeout only
    // after the flush (the bug process_runner.dart's own comment warns about)
    // would hang here until `sleep` exits on its own ~30 s later.
    final big = 'A' * (1024 * 1024);
    final sw = Stopwatch()..start();
    final r = await runner.run('sleep', ['30'],
        stdin: big, timeout: const Duration(milliseconds: 500));
    sw.stop();
    expect(r.timedOut, isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'a stdin-blocked child must still be killed at the timeout');
  });

  test('a grandchild holding the pipes cannot hang run() past the drain grace',
      () async {
    // `sh` exits immediately, but the backgrounded sleep inherits its
    // stdout/stderr pipes: exitCode completes at once while pipe EOF would
    // only come when the grandchild dies — and the SIGKILL timer cannot
    // reach a process we never started. run() must return after the bounded
    // drain, keeping the output that did arrive, not wait out the orphan.
    final sw = Stopwatch()..start();
    final r = await runner.run('sh', ['-c', 'echo early; sleep 20 & exit 0'],
        timeout: const Duration(seconds: 15));
    sw.stop();
    expect(r.exitCode, 0);
    expect(r.timedOut, isFalse,
        reason: 'the child itself exited well before the timeout');
    expect(utf8.decode(r.stdout), contains('early'),
        reason: 'output that arrived before exit must be preserved');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'must not wait for the orphaned grandchild');
  });
}
