import 'package:keybay_cli/src/command.dart';
import 'package:test/test.dart';

void main() {
  group('command parser', () {
    test('parses the two global flags', () {
      expect(parseCommand(<String>['--help']), isA<HelpCommand>());
      expect(parseCommand(<String>['--version']), isA<VersionCommand>());
    });

    test('parses run with the default manifest', () {
      final command = parseCommand(<String>[
        'run',
        '--',
        'npm',
        'start',
        '--watch',
      ]);

      expect(command, isA<RunCommand>());
      final run = command as RunCommand;
      expect(run.manifestPath, defaultManifestPath);
      expect(run.executable, 'npm');
      expect(run.arguments, <String>['start', '--watch']);
    });

    test('parses run with exactly one explicit manifest', () {
      final command =
          parseCommand(<String>[
                'run',
                '-f',
                '.secrets.staging.env',
                '--',
                'go',
                'run',
                '.',
              ])
              as RunCommand;

      expect(command.manifestPath, '.secrets.staging.env');
      expect(command.executable, 'go');
      expect(command.arguments, <String>['run', '.']);
    });

    test('requires the run delimiter and child command', () {
      for (final arguments in <List<String>>[
        <String>['run'],
        <String>['run', 'npm', 'start'],
        <String>['run', '--'],
        <String>['run', '-f'],
        <String>['run', '-f', 'file', 'npm'],
        <String>['run', '-f', 'one', '-f', 'two', '--', 'true'],
      ]) {
        expect(
          () => parseCommand(arguments),
          throwsA(isA<CliUsageException>()),
        );
      }
    });

    test('parses set only with an optional leading --stdin', () {
      final interactive =
          parseCommand(<String>['set', 'acme/project-key']) as SetCommand;
      expect(interactive.key, 'acme/project-key');
      expect(interactive.readFromStdin, isFalse);

      final piped =
          parseCommand(<String>['set', '--stdin', 'acme/project-key'])
              as SetCommand;
      expect(piped.key, 'acme/project-key');
      expect(piped.readFromStdin, isTrue);

      expect(
        () => parseCommand(<String>['set', 'acme/project-key', '--stdin']),
        throwsA(isA<CliUsageException>()),
      );
    });

    test('parses rm, list, and doctor', () {
      final remove =
          parseCommand(<String>['rm', 'acme/project-key']) as RemoveCommand;
      expect(remove.key, 'acme/project-key');
      expect(parseCommand(<String>['list']), isA<ListCommand>());
      expect(parseCommand(<String>['doctor']), isA<DoctorCommand>());
    });

    test('rejects bare keys for both mutating commands', () {
      for (final verb in <String>['set', 'rm']) {
        expect(
          () => parseCommand(<String>[verb, 'openai-api-key']),
          throwsA(isA<CliUsageException>()),
        );
      }
    });

    test('rejects extra arguments and unknown commands', () {
      for (final arguments in <List<String>>[
        <String>[],
        <String>['list', 'acme'],
        <String>['doctor', '--verbose'],
        <String>['get', 'acme/key'],
        <String>['--quiet', 'list'],
      ]) {
        expect(
          () => parseCommand(arguments),
          throwsA(isA<CliUsageException>()),
        );
      }
    });

    test('usage errors do not echo an invalid argument', () {
      const sentinel = 'do-not-echo-this-secret';
      late final CliUsageException error;
      try {
        parseCommand(<String>['set', sentinel]);
        fail('expected usage error');
      } on CliUsageException catch (caught) {
        error = caught;
      }
      expect(error.toString(), isNot(contains(sentinel)));
    });
  });
}
