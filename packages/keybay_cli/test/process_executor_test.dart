import 'dart:convert';
import 'dart:typed_data';

import 'package:keybay_cli/src/process_executor.dart';
import 'package:test/test.dart';

void main() {
  group('PATH resolution', () {
    test(
      'uses final child PATH, ignores empty entries, and preserves argv',
      () async {
        final system = _FakeExecveSystem(<String, int>{
          'relative-bin/tool': 2,
          '/usr/bin/tool': 2,
        });
        final stderr = StringBuffer();
        final executor = PosixCommandExecutor(system: system, stderr: stderr);
        const environment = <String, String>{
          'PATH': ':relative-bin::/usr/bin:',
          'SECRET': 'environment-only',
        };
        const overlay = <String, String>{'INJECTED': 'from-manifest'};

        final result = await executor.execute(
          executable: 'tool',
          arguments: const <String>['--flag', 'argument'],
          environment: environment,
          overlay: overlay,
        );

        expect(result, 127);
        expect(system.calls.map((call) => call.path), <String>[
          'relative-bin/tool',
          '/usr/bin/tool',
        ]);
        for (final call in system.calls) {
          expect(call.arguments, <String>['tool', '--flag', 'argument']);
          expect(call.arguments, isNot(contains('environment-only')));
          // Only the manifest overlay crosses the exec seam as strings; the
          // parent environment flows through raw environ, never re-encoded.
          expect(call.overlay, overlay);
          expect(call.overlay.values, isNot(contains('environment-only')));
        }
        expect(stderr.toString(), '''
error: command not found: tool
Fix PATH or use an absolute command path.
''');
      },
    );

    test('an absent or empty PATH never synthesizes cwd', () async {
      for (final environment in <Map<String, String>>[
        const <String, String>{},
        const <String, String>{'PATH': ''},
      ]) {
        final system = _FakeExecveSystem(const <String, int>{});
        final stderr = StringBuffer();
        final executor = PosixCommandExecutor(system: system, stderr: stderr);

        expect(
          await executor.execute(
            executable: 'tool',
            arguments: const <String>[],
            environment: environment,
            overlay: const <String, String>{},
          ),
          127,
        );
        expect(system.calls, isEmpty);
        expect(stderr.toString(), contains('use an absolute command path'));
      }
    });

    test('EACCES wins over pure not-found after the complete search', () async {
      final system = _FakeExecveSystem(<String, int>{
        '/one/tool': 2,
        '/two/tool': 13,
        '/three/tool': 20,
      });
      final stderr = StringBuffer();
      final executor = PosixCommandExecutor(system: system, stderr: stderr);

      expect(
        await executor.execute(
          executable: 'tool',
          arguments: const <String>[],
          environment: const <String, String>{'PATH': '/one:/two:/three'},
          overlay: const <String, String>{},
        ),
        126,
      );
      expect(system.calls, hasLength(3));
      expect(stderr.toString(), '''
error: command is not executable: tool
Check the command's executable permission and format.
''');
    });

    test(
      'ENOEXEC and unexpected errno stop the search without a shell retry',
      () async {
        for (final entry in <int, String>{
          8: 'not executable',
          5: 'errno 5',
        }.entries) {
          final system = _FakeExecveSystem(<String, int>{
            '/one/tool': entry.key,
            '/two/tool': 2,
          });
          final stderr = StringBuffer();
          final executor = PosixCommandExecutor(system: system, stderr: stderr);

          expect(
            await executor.execute(
              executable: 'tool',
              arguments: const <String>[],
              environment: const <String, String>{'PATH': '/one:/two'},
              overlay: const <String, String>{},
            ),
            126,
          );
          expect(system.calls, hasLength(1));
          expect(stderr.toString(), contains(entry.value));
          expect(
            stderr.toString(),
            contains(entry.key == 8 ? 'Check the command' : 'then retry'),
          );
          expect(system.calls.single.path, isNot('/bin/sh'));
        }
      },
    );
  });

  group('direct path', () {
    test('a slash bypasses PATH search', () async {
      final system = _FakeExecveSystem(<String, int>{'./bin/tool': 2});
      final stderr = StringBuffer();
      final executor = PosixCommandExecutor(system: system, stderr: stderr);

      expect(
        await executor.execute(
          executable: './bin/tool',
          arguments: const <String>['arg'],
          environment: const <String, String>{'PATH': '/must/not/use'},
          overlay: const <String, String>{},
        ),
        127,
      );
      expect(system.calls, hasLength(1));
      expect(system.calls.single.path, './bin/tool');
      expect(system.calls.single.arguments, <String>['./bin/tool', 'arg']);
      expect(stderr.toString(), contains('Fix PATH'));
    });

    test('maps EACCES and ENOEXEC to 126 and other errno to 126', () async {
      for (final errno in <int>[13, 8, 5]) {
        final system = _FakeExecveSystem(<String, int>{'/bin/tool': errno});
        final executor = PosixCommandExecutor(
          system: system,
          stderr: StringBuffer(),
        );
        expect(
          await executor.execute(
            executable: '/bin/tool',
            arguments: const <String>[],
            environment: const <String, String>{},
            overlay: const <String, String>{},
          ),
          126,
        );
      }
    });
  });

  group('overlayShadowsEnvEntry (raw environ passthrough)', () {
    List<Uint8List> names(List<String> values) => <Uint8List>[
      for (final value in values) utf8.encode(value),
    ];

    Uint8List entry(List<int> bytes) => Uint8List.fromList(bytes);

    test('matches exactly the overlaid name, not prefixes or suffixes', () {
      final overlay = names(<String>['INJECTED']);
      expect(
        overlayShadowsEnvEntry(utf8.encode('INJECTED=old'), overlay),
        isTrue,
      );
      expect(overlayShadowsEnvEntry(utf8.encode('INJECTED='), overlay), isTrue);
      expect(
        overlayShadowsEnvEntry(utf8.encode('INJECTED_2=x'), overlay),
        isFalse,
      );
      expect(overlayShadowsEnvEntry(utf8.encode('INJECT=x'), overlay), isFalse);
      expect(overlayShadowsEnvEntry(utf8.encode('OTHER=x'), overlay), isFalse);
    });

    test('a non-UTF-8 parent value cannot hide a shadowed name', () {
      // NAME=<0xff> — the value bytes are irrelevant to the name match.
      final raw = entry(<int>[...utf8.encode('INJECTED='), 0xff]);
      expect(overlayShadowsEnvEntry(raw, names(<String>['INJECTED'])), isTrue);
    });

    test('a non-UTF-8 parent NAME never matches an overlay name', () {
      final raw = entry(<int>[0xff, 0x3d, 0x78]); // <0xff>=x
      expect(overlayShadowsEnvEntry(raw, names(<String>['X'])), isFalse);
    });

    test('an entry without = passes through even when it equals a name', () {
      expect(
        overlayShadowsEnvEntry(utf8.encode('INJECTED'), names(['INJECTED'])),
        isFalse,
      );
      expect(
        overlayShadowsEnvEntry(entry(const <int>[]), names(['X'])),
        isFalse,
      );
    });
  });
}

final class _ExecveCall {
  _ExecveCall({
    required this.path,
    required List<String> arguments,
    required Map<String, String> overlay,
  }) : arguments = List<String>.of(arguments),
       overlay = Map<String, String>.of(overlay);

  final String path;
  final List<String> arguments;
  final Map<String, String> overlay;
}

final class _FakeExecveSystem implements ExecveSystem {
  _FakeExecveSystem(this.errors);

  final Map<String, int> errors;
  final List<_ExecveCall> calls = <_ExecveCall>[];
  int _errno = 0;

  @override
  int get errno => _errno;

  @override
  int execve({
    required String path,
    required List<String> arguments,
    required Map<String, String> overlay,
  }) {
    calls.add(_ExecveCall(path: path, arguments: arguments, overlay: overlay));
    _errno = errors[path] ?? 2;
    return -1;
  }
}
