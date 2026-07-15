@Tags(['integration'])
@TestOn('mac-os')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:keybay/keybay.dart' show SecretStorage;
import 'package:keybay/src/backend.dart';
import 'package:keybay/src/errors.dart';
import 'package:keybay/src/ffi/keychain.dart';
import 'package:test/test.dart';

/// Exercises the REAL macOS login Keychain. Opt-in — these create and delete
/// items under a throwaway service and may surface an auth dialog on some
/// machines. Run with:
///   KEYBAY_INTEGRATION=1 dart test -t integration
void main() {
  // Runtime gate (not a compile-time define): export KEYBAY_INTEGRATION=1.
  final envEnabled = Platform.environment['KEYBAY_INTEGRATION'] == '1';
  final skip = envEnabled ? false : 'set KEYBAY_INTEGRATION=1';

  final api = AppleKeychainApi();
  const service = 'ca.danreynolds.keybay.itest';

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

  test('an empty (0-byte) value round-trips and is distinct from absent',
      () async {
    // A stored empty value is *present*, not missing — the read must return an
    // empty list, never null (which callers treat as "no such item"). Some
    // keychains hand back errSecSuccess with a NULL data ref for a 0-byte
    // value; get() maps that to the empty list rather than mistaking it for a
    // miss or dereferencing NULL.
    await api.set(service, 'k', bytes(const <int>[]), label: 'empty');
    final got = await api.get(service, 'k');
    expect(got, isNotNull, reason: 'a 0-byte value is present, not absent');
    expect(got, isEmpty);
    // exists() (attributes-only) must also see it as present…
    expect(await api.exists(service, 'k'), isTrue);
    // …and a genuinely absent item is null / not-present, unchanged.
    expect(await api.get(service, 'a'), isNull);
    expect(await api.exists(service, 'a'), isFalse);

    // Overwriting the empty value with real bytes and back still round-trips.
    await api.set(service, 'k', bytes([7, 8, 9]));
    expect(await api.get(service, 'k'), [7, 8, 9]);
    await api.set(service, 'k', bytes(const <int>[]));
    expect(await api.get(service, 'k'), isEmpty);
  }, skip: skip);

  test('exists() is attributes-only and matches get()-presence', () async {
    expect(await api.exists(service, 'k'), isFalse);
    await api.set(service, 'k', bytes([1, 2, 3]));
    expect(await api.exists(service, 'k'), isTrue);
    await api.delete(service, 'k');
    expect(await api.exists(service, 'k'), isFalse);
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
      expect(info.scheme, StorageScheme.encryptedFile,
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

    test('unentitled construction never migrates and writes no marker',
        () async {
      // The file scheme is detected by the container's own existence, so there
      // is no separate .scheme marker to maintain, corrupt, or tamper with, and
      // the file branch never throws MigrationRequired. (The gained-entitlement
      // case — resolving to native with a pre-existing file container — is
      // covered by the entitled harness leg in example_flutter/.)
      expect(() => SecretStorage(appId: appId), returnsNormally);
      expect(() => SecretStorage(appId: appId), returnsNormally);
      expect(File('${dataDir.path}/.scheme').existsSync(), isFalse,
          reason: 'the marker mechanism was removed');
    }, skip: skip);
  });
}
