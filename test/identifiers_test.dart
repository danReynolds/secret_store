@Tags(['unit'])
library;

import 'package:keybay/src/identifiers.dart';
import 'package:test/test.dart';

void main() {
  group('validateIdentifier', () {
    test('accepts the documented charset', () {
      for (final ok in ['a', 'dune_db-key', 'a.b/c', 'A9._/-', 'x' * 120]) {
        validateIdentifier(ok, 'key'); // must not throw
      }
    });

    test('rejects out-of-charset and out-of-length values', () {
      for (final bad in [
        '',
        ' ',
        'has space',
        'new\nline',
        r'$(x)',
        'x' * 121,
      ]) {
        expect(
            () => validateIdentifier(bad, 'key'), throwsA(isA<ArgumentError>()),
            reason: '"$bad"');
      }
    });

    test('never echoes the offending value (transposed-secret defense)', () {
      const secret = 'hunter2-super-secret-value!';
      try {
        validateIdentifier(secret, 'key');
        fail('should have thrown');
      } on ArgumentError catch (e) {
        expect(e.toString(), isNot(contains('hunter2')),
            reason: 'a secret passed where a key was expected must not '
                'surface in the error message');
      }
    });
  });

  group('validateLabel', () {
    test('allows printable text with spaces and non-ASCII', () {
      for (final ok in [
        null,
        'Dune database key',
        'café ☕ 名前', // accented + CJK: code units >= 0xa0, never C1
        'crème brûlée\u00a0½', // U+00A0 NBSP sits just above the C1 range
        'a' * 256,
      ]) {
        validateLabel(ok); // must not throw
      }
    });

    test('rejects C0/C1 controls and DEL', () {
      for (final bad in [
        'tab\there',
        'nl\nhere',
        'bell\x07',
        'del\x7f',
        'a\u0085b', // C1 NEL
        'a\u009bb', // C1 CSI — terminal escape introducer
      ]) {
        expect(() => validateLabel(bad), throwsA(isA<ArgumentError>()),
            reason: bad);
      }
    });

    test('rejects over-long labels', () {
      expect(() => validateLabel('a' * 257), throwsA(isA<ArgumentError>()));
      validateLabel('a' * 256); // exactly at the cap is fine
    });

    test('never echoes the offending value', () {
      try {
        validateLabel('secret\x07in\x07label');
        fail('should have thrown');
      } on ArgumentError catch (e) {
        expect(e.toString(), isNot(contains('secret')));
      }
    });
  });
}
