import 'package:keybay_cli/src/key.dart';
import 'package:test/test.dart';

void main() {
  group('CLI key grammar', () {
    test('accepts qualified project and shared keys', () {
      expect(isValidCliKey('acme-payments/openai-api-key'), isTrue);
      expect(isValidCliKey('acme_shared/service.key_2'), isTrue);
      expect(isValidCliKey('acme/project/staging/database-url'), isTrue);
      expect(isValidCliKey('0/1'), isTrue);
    });

    test('rejects unqualified, empty, and malformed keys', () {
      for (final key in <String>[
        '',
        'openai-api-key',
        '/key',
        'namespace/',
        '-namespace/key',
        'namespace/-key',
        'namespace//key',
        'namespace/key with space',
        'namespace/key\n',
        'kb://namespace/key',
      ]) {
        expect(isValidCliKey(key), isFalse, reason: 'accepted "$key"');
      }
    });

    test('enforces the complete-key length cap', () {
      final accepted = 'a/${'b' * (cliKeyMaxLength - 2)}';
      expect(accepted.length, cliKeyMaxLength);
      expect(isValidCliKey(accepted), isTrue);
      expect(isValidCliKey('${accepted}b'), isFalse);
    });
  });
}
