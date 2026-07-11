@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:secret_store/secret_store.dart';
// The Linux binding and the subprocess runner are internal (not exported);
// their unit tests reach them directly.
import 'package:secret_store/src/ffi/process_runner.dart';
import 'package:secret_store/src/ffi/secret_service.dart';
import 'package:test/test.dart';

/// Scripted [ProcessRunner]: records calls and returns canned outcomes, so the
/// secret-tool command construction, base64 transport, exit-code mapping,
/// output scrubbing, and no-hang behavior are tested on any OS (no real
/// secret-tool needed). The real binary is covered by a Linux-only integration
/// test in CI.
class ScriptedRunner implements ProcessRunner {
  ScriptedRunner(this._respond);
  final ProcessRunResult Function(List<String> args, String? stdin) _respond;
  final List<List<String>> calls = [];
  final List<String?> stdins = [];

  /// The live result buffers handed back, for asserting they were scrubbed.
  final List<ProcessRunResult> results = [];

  @override
  Future<ProcessRunResult> run(String executable, List<String> args,
      {String? stdin, required Duration timeout}) async {
    calls.add(args);
    stdins.add(stdin);
    final r = _respond(args, stdin);
    results.add(r);
    return r;
  }
}

ProcessRunResult ok(String stdout) => ProcessRunResult(
    exitCode: 0,
    stdout: Uint8List.fromList(utf8.encode(stdout)),
    stderr: Uint8List(0),
    timedOut: false,
    launchFailed: false);
ProcessRunResult exit(int code) => ProcessRunResult(
    exitCode: code,
    stdout: Uint8List(0),
    stderr: Uint8List(0),
    timedOut: false,
    launchFailed: false);
ProcessRunResult timedOut() => ProcessRunResult(
    exitCode: -1,
    stdout: Uint8List(0),
    stderr: Uint8List(0),
    timedOut: true,
    launchFailed: false);
ProcessRunResult launchFailed() => ProcessRunResult(
    exitCode: -1,
    stdout: Uint8List(0),
    stderr: Uint8List(0),
    timedOut: false,
    launchFailed: true);

void main() {
  Uint8List b(List<int> v) => Uint8List.fromList(v);

  test('set writes base64 on stdin (never argv) and builds store args',
      () async {
    late List<String> args;
    final runner = ScriptedRunner((a, s) {
      args = a;
      return ok('');
    });
    final api = SecretToolApi(runner: runner);
    await api.set('svc', 'acct', b([1, 2, 3, 250]), label: 'My Label');

    expect(args, [
      'store', '--label', 'My Label', //
      '--', 'service', 'svc', 'account', 'acct'
    ]);
    expect(runner.stdins.single, base64.encode([1, 2, 3, 250]));
    // The raw value bytes must never appear in argv.
    expect(args.join(' '), isNot(contains(String.fromCharCodes([250]))));
  });

  test('set defaults the label', () async {
    final runner = ScriptedRunner((a, s) => ok(''));
    await SecretToolApi(runner: runner).set('svc', 'acct', b([9, 9]));
    expect(runner.calls.single.sublist(0, 3),
        ['store', '--label', 'secret_store']);
    expect(runner.stdins.single, base64.encode([9, 9]));
  });

  test('get decodes base64 stdout and scrubs the buffer; exit 1 is null',
      () async {
    final runner =
        ScriptedRunner((a, s) => ok('${base64.encode([9, 8, 7])}\n'));
    final found = SecretToolApi(runner: runner);
    expect(await found.get('s', 'a'), [9, 8, 7]);
    expect(runner.results.single.stdout, everyElement(0),
        reason: 'stdout (the secret) must be zeroed after decoding');

    final missing = SecretToolApi(runner: ScriptedRunner((a, s) => exit(1)));
    expect(await missing.get('s', 'a'), isNull);
  });

  test('lookup/clear build the right args (with the -- option terminator)',
      () async {
    final getRunner = ScriptedRunner((a, s) => exit(1));
    await SecretToolApi(runner: getRunner).get('svc', 'k');
    expect(getRunner.calls.single,
        ['lookup', '--', 'service', 'svc', 'account', 'k']);

    final delRunner = ScriptedRunner((a, s) => ok(''));
    await SecretToolApi(runner: delRunner).delete('svc', 'k');
    expect(delRunner.calls.single,
        ['clear', '--', 'service', 'svc', 'account', 'k']);
  });

  test('a leading-dash service is data after --, never an option', () async {
    // Regression: an appId like `--unlock` reaches secret-tool as the `service`
    // attribute value; the `--` terminator keeps it from parsing as an option.
    final runner = ScriptedRunner((a, s) => exit(1));
    await SecretToolApi(runner: runner).get('--unlock', 'k');
    final call = runner.calls.single;
    expect(call.indexOf('--') < call.indexOf('--unlock'), isTrue,
        reason: 'the terminator must precede the dash-leading value');
    expect(call, ['lookup', '--', 'service', '--unlock', 'account', 'k']);
  });

  test('delete is idempotent: clear exits 1 on a missing item (not an error)',
      () async {
    // Real gnome-keyring exits 1 from `clear` when nothing matched; that must
    // be a no-op success, not KeystoreOperationFailed. (Regression: the mock
    // previously only exercised exit 0, hiding this on the real backend.)
    final api = SecretToolApi(runner: ScriptedRunner((a, s) => exit(1)));
    await api.delete('svc', 'missing'); // must not throw
  });

  test('timeout -> KeystoreLocked (never hangs)', () async {
    final api = SecretToolApi(runner: ScriptedRunner((a, s) => timedOut()));
    await expectLater(api.get('s', 'a'), throwsA(isA<KeystoreLocked>()));
    await expectLater(
        api.set('s', 'a', b([1])), throwsA(isA<KeystoreLocked>()));
  });

  test('missing secret-tool -> KeystoreUnreachable', () async {
    final api = SecretToolApi(runner: ScriptedRunner((a, s) => launchFailed()));
    await expectLater(api.get('s', 'a'), throwsA(isA<KeystoreUnreachable>()));
    final probe = await api.probe('s');
    expect(probe.available, isFalse);
  });

  test('a store failure never leaks the value; output buffers are scrubbed',
      () async {
    // secret-tool would echo the offending stdin (the base64 value) on stderr;
    // our error must carry only the exit code, and the captured output must be
    // zeroed.
    final value = b([42, 42, 42]);
    final runner = ScriptedRunner((a, s) => ProcessRunResult(
        exitCode: 2,
        stdout: Uint8List.fromList(utf8.encode(base64.encode(value))),
        stderr: Uint8List.fromList(
            utf8.encode('bad input: ${base64.encode(value)}')),
        timedOut: false,
        launchFailed: false));
    final api = SecretToolApi(runner: runner);
    try {
      await api.set('s', 'a', value);
      fail('should have thrown');
    } on KeystoreOperationFailed catch (e) {
      expect(e.toString(), isNot(contains(base64.encode(value))));
    }
    expect(runner.results.single.stdout, everyElement(0));
    expect(runner.results.single.stderr, everyElement(0));
  });

  test(
      'getAll parses account attributes from stderr (real secret-tool split), '
      'ignores secrets on stdout, then fetches each', () async {
    // Real `secret-tool search` puts item bodies (incl. `secret = …`) on
    // stdout and `attribute.account = …` on STDERR. The mock mirrors that so
    // it exercises the same path the real backend takes.
    Uint8List enc(String s) => Uint8List.fromList(utf8.encode(s));
    final runner = ScriptedRunner((a, s) {
      if (a.first == 'search') {
        return ProcessRunResult(
          exitCode: 0,
          stdout: enc('[/1]\nlabel = x\nsecret = sup3r-s3cret-echo\n'
              '[/2]\nlabel = x\nsecret = another\n'),
          stderr: enc('attribute.account = alpha\n'
              'attribute.service = svc\n'
              'attribute.account = beta\n'
              'attribute.account_id = not-an-account\n'),
          timedOut: false,
          launchFailed: false,
        );
      }
      // lookup for a specific account
      final account = a[a.indexOf('account') + 1];
      return ok(base64.encode(account.codeUnits));
    });
    final api = SecretToolApi(runner: runner);
    final all = await api.getAll('svc');
    expect(all.keys.toSet(), {'alpha', 'beta'}); // account_id rejected
    expect(all['alpha'], 'alpha'.codeUnits);
    // Both search streams (stdout echoes secrets) must be scrubbed after parse.
    expect(runner.results.first.stdout, everyElement(0));
    expect(runner.results.first.stderr, everyElement(0));
  });

  test('empty search -> empty map', () async {
    final api = SecretToolApi(runner: ScriptedRunner((a, s) => exit(1)));
    expect(await api.getAll('svc'), isEmpty);
  });

  test('non-base64 stored value -> typed KeystoreOperationFailed', () async {
    final api =
        SecretToolApi(runner: ScriptedRunner((a, s) => ok('not valid b64 !!')));
    await expectLater(
        api.get('s', 'a'), throwsA(isA<KeystoreOperationFailed>()));
  });
}
