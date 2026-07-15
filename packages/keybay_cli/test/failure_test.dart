import 'package:keybay/keybay.dart';
import 'package:keybay_cli/src/failure.dart';
import 'package:test/test.dart';

void main() {
  test(
    'every exported core failure has remediation and the specified exit',
    () {
      final cases = <SecretStoreException, int>{
        const KeystoreLocked(): 69,
        const KeystoreUnreachable(): 69,
        const StoreKeyMissing(): 69,
        const ContainerMissing('/tmp/container'): 69,
        const WrongStoreKey(): 69,
        const AuthenticationFailed(): 69,
        const ContainerCorrupt('invalid structure'): 69,
        MigrationRequired(
          appId: 'keybay-cli',
          from: StorageScheme.encryptedFile,
          to: StorageScheme.nativeItems,
        ): 69,
        StoreTooLarge(200, 100): 69,
        SecureFileError('open', '/tmp/container', 13): 69,
        StoreBusy('/tmp/store.lock', const Duration(seconds: 10)): 75,
        const KeyInvalidated(): 69,
        const UnsupportedCapability('enumeration'): 70,
        const KeystoreOperationFailed('operation failed'): 69,
      };

      for (final entry in cases.entries) {
        final failure = failureForSecretStore(entry.key);
        expect(
          failure.exitCode,
          entry.value,
          reason: '${entry.key.runtimeType}',
        );
        expect(failure.lines, isNotEmpty, reason: '${entry.key.runtimeType}');
        expect(failure.lines.first, startsWith('error:'));
        expect(
          failure.lines.skip(1).join('\n'),
          isNotEmpty,
          reason: '${entry.key.runtimeType} must name a next action',
        );
      }
    },
  );

  test('corruption diagnostics never include backend structural details', () {
    const sentinel = 'never-echo-this-secret';
    final failure = failureForSecretStore(const ContainerCorrupt(sentinel));
    expect(failure.lines.join('\n'), isNot(contains(sentinel)));
    expect(failure.lines.join('\n'), contains(recoveryUrl));
  });

  test('unsafe-permission remediation shell-quotes the path', () {
    final failure = failureForSecretStore(
      SecureFileError('read(insecure-mode:644)', "/tmp/keybay user's/store", 0),
    );
    expect(
      failure.lines.last,
      r"Restrict it and retry: chmod 600 -- '/tmp/keybay user'\''s/store'",
    );

    final directoryFailure = failureForSecretStore(
      SecureFileError('insecure-dir-mode(755)', "/tmp/keybay user's", 0),
    );
    expect(
      directoryFailure.lines.last,
      r"Restrict it and retry: chmod 700 -- '/tmp/keybay user'\''s'",
    );

    final shapeFailure = failureForSecretStore(
      SecureFileError('read(not-a-regular-file)', '/tmp/store', 0),
    );
    expect(shapeFailure.lines.join('\n'), isNot(contains('chmod')));
  });
}
