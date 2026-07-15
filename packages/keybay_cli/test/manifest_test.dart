import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:keybay_cli/src/manifest.dart';
import 'package:test/test.dart';

void main() {
  group('manifest parser', () {
    test('parses literals, references, comments, and empty values', () {
      final manifest = _parse(
        '  # comment with leading ASCII whitespace\n'
        'API_URL=  https://staging.example.test/path?a=b  \n'
        'LOG_LEVEL=debug#not-an-inline-comment\n'
        'EMPTY=   \n'
        'OPENAI_API_KEY= kb://acme-payments/openai-api-key\t\n'
        'SHARED=kb://acme-shared/service/key\n',
      );

      expect(manifest.values.keys, <String>[
        'API_URL',
        'LOG_LEVEL',
        'EMPTY',
        'OPENAI_API_KEY',
        'SHARED',
      ]);
      expect(
        (manifest.values['API_URL']! as LiteralManifestValue).value,
        'https://staging.example.test/path?a=b',
      );
      expect(
        (manifest.values['LOG_LEVEL']! as LiteralManifestValue).value,
        'debug#not-an-inline-comment',
      );
      expect(
        (manifest.values['EMPTY']! as LiteralManifestValue).value,
        isEmpty,
      );
      expect(
        (manifest.values['OPENAI_API_KEY']! as SecretManifestValue).key,
        'acme-payments/openai-api-key',
      );
      expect(
        (manifest.values['SHARED']! as SecretManifestValue).key,
        'acme-shared/service/key',
      );
    });

    test('accepts LF, CRLF, and one leading UTF-8 BOM', () {
      final bytes = <int>[
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('A=one\r\nB=kb://acme/two\r\n'),
      ];
      final manifest = parseManifestBytes(bytes);

      expect((manifest.values['A']! as LiteralManifestValue).value, 'one');
      expect((manifest.values['B']! as SecretManifestValue).key, 'acme/two');
    });

    test('treats quotes, interpolation, and export as ordinary grammar', () {
      final manifest = _parse(r'''
QUOTED="value"
INTERPOLATED=${HOME}
''');
      expect(
        (manifest.values['QUOTED']! as LiteralManifestValue).value,
        '"value"',
      );
      expect(
        (manifest.values['INTERPOLATED']! as LiteralManifestValue).value,
        r'${HOME}',
      );
      expect(
        () => _parse('export NAME=value\n'),
        throwsA(isA<ManifestParseException>()),
      );
    });

    test('rejects invalid entry names and duplicate names', () {
      for (final source in <String>[
        ' NAME=value\n',
        'NAME =value\n',
        '1_NAME=value\n',
        'NAME\n',
        'NAME=one\nNAME=two\n',
      ]) {
        expect(() => _parse(source), throwsA(isA<ManifestParseException>()));
      }
    });

    test(
      'rejects every malformed kb reference instead of making it literal',
      () {
        for (final value in <String>[
          'kb://',
          'kb://openai-api-key',
          'kb:///key',
          'kb://namespace/',
          'kb://namespace/-key',
          'kb://namespace/key with space',
          'kb://namespace//key',
        ]) {
          expect(
            () => _parse('SECRET=$value\n'),
            throwsA(isA<ManifestParseException>()),
            reason: 'accepted $value',
          );
        }
      },
    );

    test('rejects NUL, malformed UTF-8, bare CR, and a second BOM', () {
      final cases = <String, List<int>>{
        'NUL': <int>[...utf8.encode('NAME=before'), 0, ...utf8.encode('after')],
        'malformed UTF-8': <int>[0xc3, 0x28],
        'bare CR': utf8.encode('A=one\rB=two'),
        'terminal bare CR': utf8.encode('A=one\r'),
        'second BOM': <int>[
          0xef,
          0xbb,
          0xbf,
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode('A=one'),
        ],
      };

      for (final entry in cases.entries) {
        expect(
          () => parseManifestBytes(entry.value),
          throwsA(isA<ManifestParseException>()),
          reason: entry.key,
        );
      }
    });

    test('enforces manifest and line byte limits', () {
      expect(
        () => parseManifestBytes(List<int>.filled(manifestMaxBytes + 1, 0x20)),
        throwsA(isA<ManifestParseException>()),
      );
      expect(
        () =>
            parseManifestBytes(utf8.encode('A=${'x' * manifestLineMaxBytes}')),
        throwsA(isA<ManifestParseException>()),
      );
    });

    test('counts CRLF as a line ending rather than manifest content', () {
      final line = 'A=${'x' * (manifestLineMaxBytes - 2)}';
      expect(utf8.encode(line).length, manifestLineMaxBytes);

      expect(() => _parse('$line\n'), returnsNormally);
      expect(() => _parse('$line\r\n'), returnsNormally);
    });

    test('diagnostics never echo the offending source', () {
      const sentinel = 'do-not-echo-this-secret';
      late final ManifestParseException error;
      try {
        _parse('INVALID NAME=$sentinel\n');
        fail('expected parse error');
      } on ManifestParseException catch (caught) {
        error = caught;
      }

      expect(error.toString(), isNot(contains(sentinel)));
      expect(error.toString(), startsWith('line 1:'));
    });

    test('arbitrary byte strings produce a manifest or typed parse error', () {
      final random = Random(0x4b455957);
      for (var iteration = 0; iteration < 2000; iteration++) {
        final bytes = List<int>.generate(
          random.nextInt(256),
          (_) => random.nextInt(256),
        );
        try {
          parseManifestBytes(bytes);
        } on ManifestParseException {
          // The parser's complete, expected error surface.
        } on Object catch (error) {
          fail('unexpected ${error.runtimeType} at iteration $iteration');
        }
      }
    });
  });

  test('readManifest bounds the file read', () async {
    final directory = await Directory.systemTemp.createTemp('keybay-manifest-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/.secrets.env');
    await file.writeAsBytes(List<int>.filled(manifestMaxBytes + 100, 0x20));

    await expectLater(
      readManifest(file),
      throwsA(isA<ManifestParseException>()),
    );
  });
}

Manifest _parse(String source) => parseManifestBytes(utf8.encode(source));
