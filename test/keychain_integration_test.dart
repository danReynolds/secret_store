@Tags(['integration'])
@TestOn('mac-os')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:secret_store/secret_store.dart' show SecretStorage;
import 'package:secret_store/src/backend.dart';
import 'package:secret_store/src/errors.dart';
import 'package:secret_store/src/ffi/keychain.dart';
import 'package:test/test.dart';

/// Exercises the REAL macOS login Keychain. Opt-in — these create and delete
/// items under a throwaway service and may surface an auth dialog on some
/// machines. Run with:
///   SECRET_STORE_INTEGRATION=1 dart test -t integration
void main() {
  // Runtime gate (not a compile-time define): export SECRET_STORE_INTEGRATION=1.
  final envEnabled = Platform.environment['SECRET_STORE_INTEGRATION'] == '1';
  final skip = envEnabled ? false : 'set SECRET_STORE_INTEGRATION=1';

  final api = AppleKeychainApi();
  const service = 'ca.danreynolds.secret_store.itest';

  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  Future<void> cleanup() async {
    for (final acct in ['a', 'b', 'k']) {
      await api.delete(service, acct);
    }
  }

  setUp(cleanup);
  tearDown(cleanup);

  test('add / get / update / delete round-trips real bytes', () async {
    expect(await api.get(service, 'k'), isNull);

    await api.set(service, 'k', bytes([1, 2, 3, 0, 255]), label: 'itest key');
    expect(await api.get(service, 'k'), [1, 2, 3, 0, 255]);

    // upsert (duplicate -> update)
    await api.set(service, 'k', bytes([9, 9]));
    expect(await api.get(service, 'k'), [9, 9]);

    await api.delete(service, 'k');
    expect(await api.get(service, 'k'), isNull);
    await api.delete(service, 'k'); // idempotent
  }, skip: skip);

  test('enumerates all accounts under a service', () async {
    await api.set(service, 'a', bytes([1]));
    await api.set(service, 'b', bytes([2, 2]));
    final all = await api.getAll(service);
    expect(all.keys.toSet(), containsAll(<String>{'a', 'b'}));
    expect(all['a'], [1]);
    expect(all['b'], [2, 2]);
  }, skip: skip);

  test('binary values with embedded NULs survive the CFData round-trip',
      () async {
    final v = bytes(List.generate(64, (i) => (i * 7) % 256));
    await api.set(service, 'k', v);
    expect(await api.get(service, 'k'), v);
  }, skip: skip);

  test('probe reports available/unlocked on a normal session', () async {
    final p = await api.probe(service);
    expect(p.available, isTrue);
  }, skip: skip);

  // Note: every call now carries kSecUseAuthenticationUIFail unconditionally
  // (the knob was removed) — so the round-trip tests above already prove the
  // flag is inert on an unlocked keychain, and a locked keychain fails typed.

  group('Data Protection keychain', () {
    // The SUCCESS path needs a signed, entitled app bundle, which CI can't
    // produce — that is verified manually (see doc/design.md). What IS testable
    // here, including on the unsigned CI runner, is (a) the binding constructs,
    // (b) an unentitled process is refused with the −34018 → typed error,
    // never silently falling back to the login keychain, and (c) the resolver
    // probe reports `missingEntitlement` — the exact branch every CLI takes.
    test('binding constructs', () {
      expect(AppleKeychainApi.dataProtection(), isNotNull);
    }, skip: skip);

    test(
        'probeDataProtection reports missingEntitlement on an unentitled '
        'process (the resolver branch every CLI takes)', () {
      final dp = AppleKeychainApi.dataProtection();
      expect(dp.probeDataProtection(),
          DataProtectionAvailability.missingEntitlement);
    }, skip: skip);

    test('an unentitled process is refused, not silently downgraded', () async {
      final dp = AppleKeychainApi.dataProtection();
      // errSecMissingEntitlement (−34018) → KeystoreUnreachable with guidance.
      // (An entitled app would instead store successfully.)
      await expectLater(
        dp.set(service, 'dp', bytes([1, 2, 3])),
        throwsA(
          isA<KeystoreUnreachable>()
              .having((e) => e.toString(), 'toString', contains('entitlement')),
        ),
      );
      // And nothing was written to the login keychain as a fallback.
      expect(await api.get(service, 'dp'), isNull);
    }, skip: skip);
  });

  group('resolver end-to-end (SecretStorage(appId:) on real macOS)', () {
    // On this (unentitled) test runner the resolver must take the CLI branch:
    // encrypted file under ~/Library/Application Support/<appId>/, key in the
    // login Keychain, level loginBound.
    const appId = 'ca.danreynolds.secret-store.itest-resolver';
    final home = Platform.environment['HOME']!;
    final dataDir = Directory('$home/Library/Application Support/$appId');

    Future<void> cleanupResolved() async {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      await api.delete(appId, 'store-key'); // idempotent
    }

    setUp(cleanupResolved);
    tearDown(cleanupResolved);

    test('resolves to encrypted-file + login-Keychain key and round-trips',
        () async {
      final store = SecretStorage(appId: appId);

      final info = await store.backend.describe();
      expect(info.name, 'encrypted-file',
          reason: 'unentitled process must take the file scheme');
      expect(info.level, SecurityLevel.loginBound);

      await store.writeString('token', 's3cr3t');
      expect(await store.readString('token'), 's3cr3t');

      // The container exists at the derived path, and the raw file is
      // ciphertext (the plaintext value does not appear in it).
      final file = File('${dataDir.path}/secrets.enc');
      expect(file.existsSync(), isTrue);
      expect(String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('s3cr3t')));

      // The wrapping key is a real login-Keychain item under the appId.
      expect(await api.get(appId, 'store-key'), isNotNull);

      // A second store instance (same process) reads the same data.
      expect(await SecretStorage(appId: appId).readString('token'), 's3cr3t');

      await store.delete('token');
      expect(await store.readString('token'), isNull);
    }, skip: skip);

    test('a scheme change is refused with MigrationRequired', () async {
      // Simulate a prior *entitled* provisioning by pre-seeding the marker
      // with "native". This unentitled runner resolves to "file", so the
      // resolver must refuse rather than silently use a different store.
      dataDir.createSync(recursive: true);
      Process.runSync('chmod', ['700', dataDir.path]);
      final marker = File('${dataDir.path}/.scheme')
        ..writeAsStringSync('native');
      Process.runSync('chmod', ['600', marker.path]);

      expect(
        () => SecretStorage(appId: appId),
        throwsA(isA<MigrationRequired>()
            .having((e) => e.from, 'from', 'native')
            .having((e) => e.to, 'to', 'file')),
      );
    }, skip: skip);

    test('first provision writes a matching scheme marker (no false alarm)',
        () async {
      SecretStorage(appId: appId); // resolves to file, writes marker
      final marker = File('${dataDir.path}/.scheme');
      expect(marker.existsSync(), isTrue);
      expect(marker.readAsStringSync().trim(), 'file');
      // A second construction sees a matching marker and does not throw.
      expect(() => SecretStorage(appId: appId), returnsNormally);
    }, skip: skip);
  });
}
