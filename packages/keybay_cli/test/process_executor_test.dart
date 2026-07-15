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

        final result = await executor.execute(
          executable: 'tool',
          arguments: const <String>['--flag', 'argument'],
          environment: environment,
        );

        expect(result, 127);
        expect(system.calls.map((call) => call.path), <String>[
          'relative-bin/tool',
          '/usr/bin/tool',
        ]);
        for (final call in system.calls) {
          expect(call.arguments, <String>['tool', '--flag', 'argument']);
          expect(call.arguments, isNot(contains('environment-only')));
          expect(call.environment, environment);
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
          ),
          126,
        );
      }
    });
  });
}

final class _ExecveCall {
  _ExecveCall({
    required this.path,
    required List<String> arguments,
    required Map<String, String> environment,
  }) : arguments = List<String>.of(arguments),
       environment = Map<String, String>.of(environment);

  final String path;
  final List<String> arguments;
  final Map<String, String> environment;
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
    required Map<String, String> environment,
  }) {
    calls.add(
      _ExecveCall(path: path, arguments: arguments, environment: environment),
    );
    _errno = errors[path] ?? 2;
    return -1;
  }
}
