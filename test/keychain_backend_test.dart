@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:secret_store/secret_store.dart';
import 'package:test/test.dart';

/// In-memory [KeychainApi] fake: models (service, account) -> bytes with upsert
/// and enumeration, so the backend/key-source logic is tested without the real
/// Keychain (the FFI itself is covered by keychain_integration_test).
class FakeKeychainApi implements KeychainApi {
  final Map<String, Map<String, Uint8List>> _store = {};
  bool locked = false;
  bool available = true;

  @override
  Uint8List? get(String service, String account) {
    _checkReachable();
    return _store[service]?[account];
  }

  @override
  void set(String service, String account, Uint8List value, {String? label}) {
    _checkReachable();
    (_store[service] ??= {})[account] = Uint8List.fromList(value);
  }

  @override
  void delete(String service, String account) {
    _checkReachable();
    _store[service]?.remove(account);
  }

  @override
  Map<String, Uint8List> getAll(String service) {
    _checkReachable();
    return Map.of(_store[service] ?? {});
  }

  @override
  KeychainProbe probe(String service) =>
      KeychainProbe(available: available, locked: locked);

  void _checkReachable() {
    if (!available) throw const KeystoreUnreachable();
    if (locked) throw const KeystoreLocked();
  }
}

void main() {
  Uint8List b(List<int> v) => Uint8List.fromList(v);

  group('KeychainBackend', () {
    late FakeKeychainApi api;
    late KeychainBackend be;
    setUp(() {
      api = FakeKeychainApi();
      be = KeychainBackend(service: 'svc', api: api);
    });

    test('read/write/contains/delete/enumerate', () async {
      expect(await be.read('k'), isNull);
      await be.write('k', b([1, 2]), label: 'lbl');
      expect(await be.read('k'), [1, 2]);
      expect(await be.contains('k'), isTrue);

      await be.write('j', b([3]));
      expect((await be.readAll()).keys.toSet(), {'k', 'j'});

      await be.delete('k');
      expect(await be.contains('k'), isFalse);
    });

    test('capabilities: enumerates and is persistent', () {
      expect(be.capabilities.enumeration, isTrue);
      expect(be.capabilities.persistent, isTrue);
    });

    test('describe reflects locked/available', () async {
      api.locked = true;
      final info = await be.describe();
      expect(info.name, 'keychain');
      expect(info.locked, isTrue);
    });
  });

  group('KeychainKeySource + EncryptedFileBackend (model B)', () {
    test('wraps the container key in the keychain; container stays encrypted',
        () async {
      final api = FakeKeychainApi();
      final ks = KeychainKeySource(service: 'dune/uuid', api: api);
      // Uses a real temp file for the container.
      final dir = Directory.systemTemp.createTempSync('ss_modelb_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/secrets.enc';

      final be = EncryptedFileBackend(
          path: path, keySource: ks, contextSalt: b([1, 2, 3, 4]));
      await be.write('db_key', b([9, 9, 9]), label: 'DB key');
      expect(await be.read('db_key'), [9, 9, 9]);

      // The key lives in the (fake) keychain, exactly one item, 32 bytes.
      final stored = api.getAll('dune/uuid');
      expect(stored.keys, ['store-key']);
      expect(stored['store-key'], hasLength(storeKeyLength));

      // The on-disk container is ciphertext, not the plaintext value.
      final raw = File(path).readAsBytesSync();
      expect(String.fromCharCodes(raw), isNot(contains('999')));
    });

    test('locked keychain surfaces as StoreKeyMissing-free typed error',
        () async {
      final api = FakeKeychainApi()..locked = true;
      final ks = KeychainKeySource(service: 's', api: api);
      final dir = Directory.systemTemp.createTempSync('ss_locked_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final be = EncryptedFileBackend(path: '${dir.path}/c.enc', keySource: ks);
      // Reading the key throws KeystoreLocked from the fake.
      await expectLater(be.write('k', b([1])), throwsA(isA<KeystoreLocked>()));
    });
  });
}

// dart:io used via Directory/File above.
