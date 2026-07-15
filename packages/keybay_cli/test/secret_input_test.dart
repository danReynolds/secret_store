import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:keybay_cli/src/secret_input.dart';
import 'package:test/test.dart';

void main() {
  group('stdin secret decoding', () {
    test('strips exactly one LF or CRLF and keeps a lone CR', () {
      expect(decodeSecretBytes(utf8.encode('value\n')), 'value');
      expect(decodeSecretBytes(utf8.encode('value\r\n')), 'value');
      expect(decodeSecretBytes(utf8.encode('value\n\n')), 'value\n');
      expect(decodeSecretBytes(utf8.encode('value\r')), 'value\r');
      expect(decodeSecretBytes(const <int>[]), '');
      expect(decodeSecretBytes(utf8.encode('\n')), '');
    });

    test('rejects malformed UTF-8 and NUL without echoing input', () {
      const sentinel = 'never-echo-this-input';
      for (final entry in <(List<int>, String)>[
        (<int>[0xff, 0xfe], 'provide a UTF-8 text value'),
        (utf8.encode('$sentinel\u0000tail'), 'provide text without NUL'),
      ]) {
        late final SecretInputException error;
        try {
          decodeSecretBytes(entry.$1);
          fail('expected input failure');
        } on SecretInputException catch (caught) {
          error = caught;
        }
        expect(error.toString(), isNot(contains(sentinel)));
        expect(error.message, contains(entry.$2));
      }
    });

    test('rejects input beyond the core store envelope before decoding', () {
      final oversized = Uint8List(maxSecretInputBytes + 1);
      expect(
        () => decodeSecretBytes(oversized),
        throwsA(
          isA<SecretInputException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('16 MiB store envelope'),
              contains('credential rather than a blob'),
            ),
          ),
        ),
      );
    });
  });

  group('reader', () {
    test('--stdin reads to EOF without requiring a terminal', () async {
      final terminal = _FakeTerminal(hasTerminal: false, echoMode: true);
      final reader = SecretInputReader(
        input: Stream<List<int>>.fromIterable(<List<int>>[
          utf8.encode('multi'),
          utf8.encode('-chunk\n'),
        ]),
        terminal: terminal,
        stderr: StringBuffer(),
      );

      expect(
        await reader.read(key: 'acme/key', fromStdin: true),
        'multi-chunk',
      );
      expect(terminal.setCalls, isEmpty);
    });

    test('--stdin bounds the stream at the core store envelope', () async {
      const sentinel = 'tail-must-not-be-consumed-or-echoed';
      final reader = SecretInputReader(
        input: Stream<List<int>>.fromIterable(<List<int>>[
          Uint8List(maxSecretInputBytes + 2),
          utf8.encode(sentinel),
        ]),
        terminal: _FakeTerminal(hasTerminal: false, echoMode: true),
        stderr: StringBuffer(),
      );

      await expectLater(
        reader.read(key: 'acme/key', fromStdin: true),
        throwsA(
          isA<SecretInputException>().having(
            (error) => error.message,
            'message',
            contains('16 MiB store envelope'),
          ),
        ),
      );
    });

    test('interactive mode refuses redirected stdin', () async {
      final reader = SecretInputReader(
        input: const Stream<List<int>>.empty(),
        terminal: _FakeTerminal(hasTerminal: false, echoMode: true),
        stderr: StringBuffer(),
      );

      await expectLater(
        reader.read(key: 'acme/key', fromStdin: false),
        throwsA(
          isA<SecretInputException>().having(
            (error) => error.message,
            'guidance',
            contains('--stdin'),
          ),
        ),
      );
    });

    test(
      'interactive mode hides input and restores the exact prior mode',
      () async {
        const sentinel = 'hidden-value';
        for (final previousMode in <bool>[true, false]) {
          final terminal = _FakeTerminal(
            hasTerminal: true,
            echoMode: previousMode,
          );
          final stderr = StringBuffer();
          final reader = SecretInputReader(
            input: Stream<List<int>>.value(utf8.encode('$sentinel\nignored')),
            terminal: terminal,
            stderr: stderr,
          );

          expect(
            await reader.read(key: 'acme/key', fromStdin: false),
            sentinel,
          );
          expect(terminal.echoMode, previousMode);
          expect(terminal.setCalls.first, isFalse);
          expect(terminal.setCalls.last, previousMode);
          expect(stderr.toString(), contains('Value for acme/key'));
          expect(stderr.toString(), isNot(contains(sentinel)));
        }
      },
    );

    test('interactive mode restores echo when decoding fails', () async {
      final terminal = _FakeTerminal(hasTerminal: true, echoMode: true);
      final reader = SecretInputReader(
        input: Stream<List<int>>.value(<int>[0xff, 0x0a]),
        terminal: terminal,
        stderr: StringBuffer(),
      );

      await expectLater(
        reader.read(key: 'acme/key', fromStdin: false),
        throwsA(isA<SecretInputException>()),
      );
      expect(terminal.echoMode, isTrue);
      expect(terminal.setCalls, <bool>[false, true]);
    });

    test(
      'interactive mode cancels input when echo restoration fails',
      () async {
        var inputCancelled = false;
        final input = StreamController<List<int>>(
          onCancel: () => inputCancelled = true,
        );
        final terminal = _FakeTerminal(
          hasTerminal: true,
          echoMode: true,
          failOnSetCall: 2,
        );
        final reader = SecretInputReader(
          input: input.stream,
          terminal: terminal,
          stderr: StringBuffer(),
        );

        final read = reader.read(key: 'acme/key', fromStdin: false);
        input.add(utf8.encode('value\n'));

        await expectLater(read, throwsA(isA<StateError>()));
        expect(inputCancelled, isTrue);
        expect(terminal.setCalls, <bool>[false, true]);
        await input.close();
      },
    );

    test('interactive mode accepts a chunked final line at EOF', () async {
      final terminal = _FakeTerminal(hasTerminal: true, echoMode: true);
      final reader = SecretInputReader(
        input: Stream<List<int>>.fromIterable(<List<int>>[
          utf8.encode('chunked-'),
          utf8.encode('value'),
        ]),
        terminal: terminal,
        stderr: StringBuffer(),
      );

      expect(
        await reader.read(key: 'acme/key', fromStdin: false),
        'chunked-value',
      );
      expect(terminal.echoMode, isTrue);
      expect(terminal.setCalls, <bool>[false, true]);
    });

    test('interactive mode bounds input before a newline arrives', () async {
      final terminal = _FakeTerminal(hasTerminal: true, echoMode: true);
      final reader = SecretInputReader(
        input: Stream<List<int>>.value(Uint8List(maxSecretInputBytes + 2)),
        terminal: terminal,
        stderr: StringBuffer(),
      );

      await expectLater(
        reader.read(key: 'acme/key', fromStdin: false),
        throwsA(
          isA<SecretInputException>().having(
            (error) => error.message,
            'message',
            contains('16 MiB store envelope'),
          ),
        ),
      );
      expect(terminal.echoMode, isTrue);
      expect(terminal.setCalls, <bool>[false, true]);
    });
  });
}

final class _FakeTerminal implements TerminalControl {
  _FakeTerminal({
    required this.hasTerminal,
    required bool echoMode,
    this.failOnSetCall,
  }) : _echoMode = echoMode;

  @override
  final bool hasTerminal;
  bool _echoMode;
  final int? failOnSetCall;
  final List<bool> setCalls = <bool>[];

  @override
  bool get echoMode => _echoMode;

  @override
  set echoMode(bool value) {
    setCalls.add(value);
    if (setCalls.length == failOnSetCall) {
      throw StateError('terminal disappeared');
    }
    _echoMode = value;
  }
}
