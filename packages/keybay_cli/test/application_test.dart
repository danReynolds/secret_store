import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';
import 'package:keybay_cli/src/application.dart';
import 'package:keybay_cli/src/command.dart';
import 'package:keybay_cli/src/manifest.dart';
import 'package:test/test.dart';

void main() {
  test('help and version are complete, compact, and storage-free', () async {
    final stdout = StringBuffer();
    final application = CliApplication(
      loadManifest: (_) => throw StateError('manifest loaded'),
      createStorage: () => throw StateError('storage constructed'),
      readSecretValue: _unusedSecretReader,
      commandExecutor: _FakeCommandExecutor(),
      parentEnvironment: const <String, String>{},
      stdout: stdout,
      stderr: StringBuffer(),
    );

    expect(await application.execute(const HelpCommand()), exitSuccess);
    final helpLines = stdout.toString().trimRight().split('\n');
    expect(helpLines.length, lessThanOrEqualTo(24));
    expect(
      helpLines.map((line) => line.length),
      everyElement(lessThanOrEqualTo(80)),
    );
    for (final command in <String>['run', 'set', 'rm', 'list', 'doctor']) {
      expect(stdout.toString(), contains(command));
    }

    stdout.clear();
    expect(await application.execute(const VersionCommand()), exitSuccess);
    expect(stdout.toString(), '0.1.0\n');
  });

  group('run', () {
    test('literal-only manifests never construct storage', () async {
      final executor = _FakeCommandExecutor();
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final application = CliApplication(
        loadManifest: (_) async => Manifest(<String, ManifestValue>{
          'API_URL': const LiteralManifestValue('https://example.test'),
          'EMPTY': const LiteralManifestValue(''),
        }),
        createStorage: () => throw StateError('storage was constructed'),
        readSecretValue: _unusedSecretReader,
        commandExecutor: executor,
        parentEnvironment: const <String, String>{
          'PATH': '/usr/bin',
          'API_URL': 'inherited',
          'UNCHANGED': 'yes',
        },
        stdout: stdout,
        stderr: stderr,
      );

      final result = await application.execute(
        RunCommand(
          manifestPath: '.secrets.env',
          executable: 'server',
          arguments: <String>['--port', '3000'],
        ),
      );

      expect(result, 0);
      expect(executor.calls, hasLength(1));
      expect(executor.calls.single.executable, 'server');
      expect(executor.calls.single.arguments, <String>['--port', '3000']);
      expect(executor.calls.single.environment, <String, String>{
        'PATH': '/usr/bin',
        'API_URL': 'https://example.test',
        'UNCHANGED': 'yes',
        'EMPTY': '',
      });
      // The overlay is exactly the manifest's entries: the executor
      // materializes these and passes the rest of the parent environment
      // through byte-exact from raw environ.
      expect(executor.calls.single.overlay, <String, String>{
        'API_URL': 'https://example.test',
        'EMPTY': '',
      });
      expect(stdout.toString(), isEmpty);
      expect(stderr.toString(), isEmpty);
    });

    test(
      'resolves namespaced references and overlays only named variables',
      () async {
        final backend = _MemoryBackend(<String, List<int>>{
          'acme-api/openai-key': utf8.encode('project-value'),
          'acme-shared/stripe-key': utf8.encode('shared-value'),
          'other-project/openai-key': utf8.encode('other-value'),
        });
        final executor = _FakeCommandExecutor();
        final application = _application(
          backend: backend,
          executor: executor,
          manifest: Manifest(<String, ManifestValue>{
            'OPENAI_API_KEY': const SecretManifestValue('acme-api/openai-key'),
            'OPENAI_ALIAS': const SecretManifestValue('acme-api/openai-key'),
            'STRIPE_KEY': const SecretManifestValue('acme-shared/stripe-key'),
            'LOG_LEVEL': const LiteralManifestValue('debug'),
          }),
          parentEnvironment: const <String, String>{
            'OPENAI_API_KEY': 'inherited',
            'PARENT_ONLY': 'kept',
          },
        );

        final result = await application.execute(
          RunCommand(
            manifestPath: '.secrets.env',
            executable: 'true',
            arguments: const <String>[],
          ),
        );

        expect(result, 0);
        expect(backend.readAllCalls, 1);
        expect(executor.calls.single.environment, <String, String>{
          'OPENAI_API_KEY': 'project-value',
          'PARENT_ONLY': 'kept',
          'OPENAI_ALIAS': 'project-value',
          'STRIPE_KEY': 'shared-value',
          'LOG_LEVEL': 'debug',
        });
        expect(
          executor.calls.single.environment.values,
          isNot(contains('other-value')),
        );
        expect(executor.calls.single.overlay, <String, String>{
          'OPENAI_API_KEY': 'project-value',
          'OPENAI_ALIAS': 'project-value',
          'STRIPE_KEY': 'shared-value',
          'LOG_LEVEL': 'debug',
        });
        expect(
          executor.calls.single.overlay.keys,
          isNot(contains('PARENT_ONLY')),
        );
      },
    );

    test(
      'different repository namespaces keep the same env name independent',
      () async {
        final backend = _MemoryBackend(<String, List<int>>{
          'acme-api/openai-key': utf8.encode('api-value'),
          'acme-web/openai-key': utf8.encode('web-value'),
        });

        for (final entry in <String, String>{
          'acme-api/openai-key': 'api-value',
          'acme-web/openai-key': 'web-value',
        }.entries) {
          final executor = _FakeCommandExecutor();
          final application = _application(
            backend: backend,
            executor: executor,
            manifest: Manifest(<String, ManifestValue>{
              'OPENAI_API_KEY': SecretManifestValue(entry.key),
            }),
          );

          expect(
            await application.execute(
              RunCommand(
                manifestPath: '.secrets.env',
                executable: 'true',
                arguments: const <String>[],
              ),
            ),
            exitSuccess,
          );
          expect(
            executor.calls.single.environment['OPENAI_API_KEY'],
            entry.value,
          );
        }
      },
    );

    test(
      'two repositories using one complete reference share its value',
      () async {
        final backend = _MemoryBackend(<String, List<int>>{
          'acme-shared/openai-key': utf8.encode('shared-value'),
        });

        for (final repository in <String>['api', 'web']) {
          final executor = _FakeCommandExecutor();
          final application = _application(
            backend: backend,
            executor: executor,
            manifest: Manifest(<String, ManifestValue>{
              'OPENAI_API_KEY': const SecretManifestValue(
                'acme-shared/openai-key',
              ),
            }),
          );

          expect(
            await application.execute(
              RunCommand(
                manifestPath: '.secrets.$repository.env',
                executable: 'true',
                arguments: const <String>[],
              ),
            ),
            exitSuccess,
          );
          expect(
            executor.calls.single.environment['OPENAI_API_KEY'],
            'shared-value',
          );
        }
      },
    );

    test('reports every missing key once and launches nothing', () async {
      final backend = _MemoryBackend(<String, List<int>>{
        'acme/present': utf8.encode('present-value'),
      });
      final executor = _FakeCommandExecutor();
      final stderr = StringBuffer();
      final application = _application(
        backend: backend,
        executor: executor,
        stderr: stderr,
        manifest: Manifest(<String, ManifestValue>{
          'PRESENT': const SecretManifestValue('acme/present'),
          'MISSING_A': const SecretManifestValue('acme/missing-a'),
          'MISSING_A_ALIAS': const SecretManifestValue('acme/missing-a'),
          'MISSING_B': const SecretManifestValue('shared/missing-b'),
        }),
      );

      final result = await application.execute(
        RunCommand(
          manifestPath: '.secrets.env',
          executable: 'must-not-launch',
          arguments: const <String>[],
        ),
      );

      expect(result, exitConfig);
      expect(executor.calls, isEmpty);
      expect(
        stderr.toString(),
        'error: 3 of 4 references in .secrets.env are not set on this machine:\n'
        '\n'
        '  keybay set acme/missing-a\n'
        '  keybay set shared/missing-b\n'
        '\n'
        'Nothing was launched.\n',
      );
    });

    test('maps unreadable and malformed manifests to config failure', () async {
      final unreadableError = StringBuffer();
      final unreadable = _application(
        stderr: unreadableError,
        loadManifest: (_) => throw const FileSystemException('denied'),
      );
      expect(
        await unreadable.execute(
          RunCommand(
            manifestPath: '.secrets.env',
            executable: 'true',
            arguments: const <String>[],
          ),
        ),
        exitConfig,
      );
      expect(unreadableError.toString(), contains('could not be read'));
      expect(unreadableError.toString(), contains('Nothing was launched.'));

      final malformedError = StringBuffer();
      final malformed = _application(
        stderr: malformedError,
        loadManifest: (_) =>
            throw const ManifestParseException('expected NAME=VALUE', line: 2),
      );
      expect(
        await malformed.execute(
          RunCommand(
            manifestPath: '.secrets.env',
            executable: 'true',
            arguments: const <String>[],
          ),
        ),
        exitConfig,
      );
      expect(malformedError.toString(), contains('line 2'));
      expect(malformedError.toString(), contains('Nothing was launched.'));
    });

    test('decodes only referenced stored values', () async {
      final backend = _MemoryBackend(<String, List<int>>{
        'acme/text': utf8.encode('usable'),
        'acme/binary': <int>[0xff, 0x00, 0xfe],
      });
      final executor = _FakeCommandExecutor();
      final application = _application(
        backend: backend,
        executor: executor,
        manifest: Manifest(<String, ManifestValue>{
          'TEXT': const SecretManifestValue('acme/text'),
        }),
      );

      expect(
        await application.execute(
          RunCommand(
            manifestPath: '.secrets.env',
            executable: 'true',
            arguments: const <String>[],
          ),
        ),
        0,
      );
      expect(executor.calls.single.environment['TEXT'], 'usable');
    });

    test(
      'rejects referenced non-UTF-8 and NUL values without echoing them',
      () async {
        for (final entry in <String, List<int>>{
          'not UTF-8': <int>[0xff, 0xfe],
          'contains NUL': utf8.encode('sentinel-before\u0000sentinel-after'),
        }.entries) {
          final backend = _MemoryBackend(<String, List<int>>{
            'acme/bad': entry.value,
          });
          final stderr = StringBuffer();
          final application = _application(
            backend: backend,
            stderr: stderr,
            manifest: Manifest(<String, ManifestValue>{
              'BAD': const SecretManifestValue('acme/bad'),
            }),
          );

          expect(
            await application.execute(
              RunCommand(
                manifestPath: '.secrets.env',
                executable: 'true',
                arguments: const <String>[],
              ),
            ),
            exitConfig,
            reason: entry.key,
          );
          expect(stderr.toString(), contains('acme/bad'));
          expect(stderr.toString(), isNot(contains('sentinel')));
        }
      },
    );
  });

  group('storage commands', () {
    test('maps core failures at the application boundary', () async {
      for (final entry in <SecretStoreException, int>{
        const KeystoreUnreachable(): exitUnavailable,
        StoreBusy('/tmp/store.lock', const Duration(seconds: 10)): exitTempFail,
        const UnsupportedCapability('enumeration'): exitSoftware,
      }.entries) {
        final stderr = StringBuffer();
        final application = _application(
          stderr: stderr,
          createStorage: () => throw entry.key,
        );

        expect(
          await application.execute(const ListCommand()),
          entry.value,
          reason: '${entry.key.runtimeType}',
        );
        expect(stderr.toString(), startsWith('error:'));
      }
    });

    test(
      'set writes through the core and only interactive mode acknowledges',
      () async {
        final backend = _MemoryBackend();
        final interactiveError = StringBuffer();
        final interactive = _application(
          backend: backend,
          stderr: interactiveError,
          secretValue: 'interactive-secret',
        );
        expect(
          await interactive.execute(
            const SetCommand(key: 'acme/key', readFromStdin: false),
          ),
          0,
        );
        expect(utf8.decode(backend.values['acme/key']!), 'interactive-secret');
        expect(interactiveError.toString(), 'Stored.\n');

        final pipedError = StringBuffer();
        final piped = _application(
          backend: backend,
          stderr: pipedError,
          secretValue: 'piped-secret',
        );
        expect(
          await piped.execute(
            const SetCommand(key: 'acme/key', readFromStdin: true),
          ),
          0,
        );
        expect(utf8.decode(backend.values['acme/key']!), 'piped-secret');
        expect(pipedError.toString(), isEmpty);
        expect(backend.labels, everyElement(isNull));
      },
    );

    test('rm is idempotent and silent', () async {
      final backend = _MemoryBackend(<String, List<int>>{
        'acme/key': utf8.encode('value'),
      });
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final application = _application(
        backend: backend,
        stdout: stdout,
        stderr: stderr,
      );

      for (var iteration = 0; iteration < 2; iteration++) {
        expect(await application.execute(const RemoveCommand('acme/key')), 0);
      }
      expect(backend.values, isEmpty);
      expect(backend.deleteCalls, 2);
      expect(stdout.toString(), isEmpty);
      expect(stderr.toString(), isEmpty);
    });

    test('list writes sorted qualified names and never values', () async {
      const sentinel = 'never-print-this-value';
      final backend = _MemoryBackend(<String, List<int>>{
        'zeta/key': utf8.encode(sentinel),
        'acme/key': utf8.encode('other-value'),
        'acme/project/key': <int>[0xff, 0xfe],
      });
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final application = _application(
        backend: backend,
        stdout: stdout,
        stderr: stderr,
      );

      expect(await application.execute(const ListCommand()), 0);
      expect(stdout.toString(), 'acme/key\nacme/project/key\nzeta/key\n');
      expect(stdout.toString(), isNot(contains(sentinel)));
      expect(stderr.toString(), isEmpty);
    });
  });

  group('doctor', () {
    test('reports the backend and returns healthy only when usable', () async {
      final stdout = StringBuffer();
      final application = _application(
        backend: _MemoryBackend.withInfo(
          const BackendInfo(
            scheme: StorageScheme.encryptedFile,
            available: true,
            locked: false,
            capabilities: _memoryCapabilities,
            level: SecurityLevel.loginBound,
            detail: 'container=present key=present via test',
          ),
        ),
        stdout: stdout,
        isCompiled: true,
      );

      expect(await application.execute(const DoctorCommand()), exitSuccess);
      expect(
        stdout.toString(),
        'scheme:   encrypted file\n'
        'level:    loginBound\n'
        'keystore: reachable, unlocked\n'
        'detail:   container=present key=present via test\n'
        'runtime:  compiled executable (signature not inspected)\n'
        'keybay:   0.1.0\n',
      );
    });

    test('reports unhealthy snapshots before returning unavailable', () async {
      final stdout = StringBuffer();
      final application = _application(
        backend: _MemoryBackend.withInfo(
          const BackendInfo(
            scheme: StorageScheme.nativeItems,
            available: false,
            locked: true,
            capabilities: _memoryCapabilities,
          ),
        ),
        stdout: stdout,
      );

      expect(await application.execute(const DoctorCommand()), exitUnavailable);
      expect(stdout.toString(), contains('keystore: unreachable, locked'));
      expect(
        stdout.toString(),
        contains('runtime:  Dart VM (shared VM is the keychain trust unit)'),
      );
    });
  });
}

CliApplication _application({
  _MemoryBackend? backend,
  Manifest? manifest,
  _FakeCommandExecutor? executor,
  StringBuffer? stdout,
  StringBuffer? stderr,
  String secretValue = 'secret-value',
  Map<String, String> parentEnvironment = const <String, String>{},
  bool isCompiled = false,
  ManifestLoader? loadManifest,
  StorageFactory? createStorage,
}) {
  final effectiveBackend = backend ?? _MemoryBackend();
  return CliApplication(
    loadManifest:
        loadManifest ??
        (_) async => manifest ?? Manifest(<String, ManifestValue>{}),
    createStorage:
        createStorage ?? () => SecretStorage.withBackend(effectiveBackend),
    readSecretValue: ({required key, required fromStdin}) async => secretValue,
    commandExecutor: executor ?? _FakeCommandExecutor(),
    parentEnvironment: parentEnvironment,
    stdout: stdout ?? StringBuffer(),
    stderr: stderr ?? StringBuffer(),
    isCompiled: isCompiled,
  );
}

Future<String> _unusedSecretReader({
  required String key,
  required bool fromStdin,
}) => throw StateError('secret reader was called');

final class _ExecutionCall {
  _ExecutionCall({
    required this.executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Map<String, String> overlay,
  }) : arguments = List<String>.of(arguments),
       environment = Map<String, String>.of(environment),
       overlay = Map<String, String>.of(overlay);

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final Map<String, String> overlay;
}

final class _FakeCommandExecutor implements CommandExecutor {
  final List<_ExecutionCall> calls = <_ExecutionCall>[];
  int result = 0;

  @override
  Future<int> execute({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Map<String, String> overlay,
  }) async {
    calls.add(
      _ExecutionCall(
        executable: executable,
        arguments: arguments,
        environment: environment,
        overlay: overlay,
      ),
    );
    return result;
  }
}

const _memoryCapabilities = BackendCapabilities(
  enumeration: true,
  persistent: false,
);

final class _MemoryBackend implements SecretBackend {
  _MemoryBackend([Map<String, List<int>> initial = const <String, List<int>>{}])
    : info = const BackendInfo(
        scheme: StorageScheme.encryptedFile,
        available: true,
        locked: false,
        capabilities: _memoryCapabilities,
        level: SecurityLevel.loginBound,
        detail: 'memory',
      ),
      values = <String, Uint8List>{
        for (final entry in initial.entries)
          entry.key: Uint8List.fromList(entry.value),
      };

  _MemoryBackend.withInfo(this.info) : values = <String, Uint8List>{};

  final Map<String, Uint8List> values;
  final BackendInfo info;
  final List<String?> labels = <String?>[];
  int readAllCalls = 0;
  int deleteCalls = 0;

  @override
  BackendCapabilities get capabilities => _memoryCapabilities;

  @override
  Future<bool> contains(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    deleteCalls++;
    values.remove(key);
  }

  @override
  Future<BackendInfo> describe() async => info;

  @override
  Future<Uint8List?> read(String key) async => values[key];

  @override
  Future<Map<String, Uint8List>> readAll() async {
    readAllCalls++;
    return Map<String, Uint8List>.of(values);
  }

  @override
  Future<void> write(String key, Uint8List value, {String? label}) async {
    values[key] = Uint8List.fromList(value);
    labels.add(label);
  }
}
