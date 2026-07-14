@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:keyway/keyway.dart';
// The concrete backends are internal (not exported); their unit tests reach
// them directly.
import 'package:keyway/src/backends/encrypted_file_backend.dart';
import 'package:keyway/src/backends/keystore_backend.dart';
import 'package:keyway/src/ffi/keystore_api.dart';
import 'package:keyway/src/key_source.dart';
import 'package:test/test.dart';

/// In-memory [KeystoreApi] fake: models (service, account) -> bytes with upsert
/// and enumeration, so the backend/key-source logic is tested without the real
/// Keychain (the FFI itself is covered by keychain_integration_test).
class FakeKeystoreApi implements KeystoreApi {
  final Map<String, Map<String, Uint8List>> _store = {};
  bool locked = false;
  bool available = true;

  @override
  Future<Uint8List?> get(String service, String account) async {
    _checkReachable();
    return _store[service]?[account];
  }

  @override
  Future<bool> exists(String service, String account) async {
    _checkReachable();
    return _store[service]?.containsKey(account) ?? false;
  }

  @override
  Future<void> set(String service, String account, Uint8List value,
      {String? label}) async {
    _checkReachable();
    (_store[service] ??= {})[account] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String service, String account) async {
    _checkReachable();
    _store[service]?.remove(account);
  }

  @override
  Future<Map<String, Uint8List>> getAll(String service) async {
    _checkReachable();
    return Map.of(_store[service] ?? {});
  }

  @override
  Future<KeystoreProbe> probe(String service) async =>
      KeystoreProbe(available: available, locked: locked);

  void _checkReachable() {
    if (!available) throw const KeystoreUnreachable();
    if (locked) throw const KeystoreLocked();
  }
}

void main() {
  Uint8List b(List<int> v) => Uint8List.fromList(v);

  group('KeystoreBackend', () {
    late FakeKeystoreApi api;
    late KeystoreBackend be;
    setUp(() {
      api = FakeKeystoreApi();
      be = KeystoreBackend(service: 'svc', api: api);
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
      expect(info.scheme, StorageScheme.nativeItems);
      expect(info.locked, isTrue);
    });
  });

  group('SystemKeySource + EncryptedFileBackend (model B)', () {
    test('wraps the container key in the keychain; container stays encrypted',
        () async {
      final api = FakeKeystoreApi();
      final ks = SystemKeySource(service: 'dune/uuid', api: api);
      // Uses a real temp file for the container.
      final dir = Directory.systemTemp.createTempSync('ss_modelb_');
      Process.runSync('chmod',
          ['700', dir.path]); // private store dir (umask is 0755 on Linux)
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/secrets.enc';

      final be = EncryptedFileBackend(
          path: path, keySource: ks, contextSalt: b([1, 2, 3, 4]));
      // A distinctive ASCII plaintext marker, so "the container is ciphertext"
      // is a real assertion: the previous value [9,9,9] stringifies to tab
      // bytes and could never contain the digits "999" it checked for — the
      // test passed even against a hypothetical plaintext container.
      const marker = 'PLAINTEXT-MARKER-9f3a2b';
      final value = Uint8List.fromList(marker.codeUnits);
      await be.write('db_key', value, label: 'DB key');
      expect(await be.read('db_key'), value);

      // The key lives in the (fake) keychain, exactly one item, 32 bytes.
      final stored = await api.getAll('dune/uuid');
      expect(stored.keys, ['store-key']);
      expect(stored['store-key'], hasLength(storeKeyLength));

      // The on-disk container is ciphertext — the marker must not survive in
      // the clear.
      final raw = File(path).readAsBytesSync();
      expect(String.fromCharCodes(raw), isNot(contains(marker)),
          reason: 'container must be ciphertext, not plaintext');
    });

    test('locked keychain surfaces as StoreKeyMissing-free typed error',
        () async {
      final api = FakeKeystoreApi()..locked = true;
      final ks = SystemKeySource(service: 's', api: api);
      final dir = Directory.systemTemp.createTempSync('ss_locked_');
      Process.runSync('chmod',
          ['700', dir.path]); // private store dir (umask is 0755 on Linux)
      addTearDown(() => dir.deleteSync(recursive: true));
      final be = EncryptedFileBackend(path: '${dir.path}/c.enc', keySource: ks);
      // Reading the key throws KeystoreLocked from the fake.
      await expectLater(be.write('k', b([1])), throwsA(isA<KeystoreLocked>()));
    });

    test('SystemKeySource.describe checks presence without reading the key',
        () async {
      final src =
          SystemKeySource(service: 'svc', api: _GetMustNotBeCalledApi());
      final status = await src.describe();
      expect(status.present, isTrue);
      expect(status.available, isTrue);
    });

    test(
        'SystemKeySource.describe never throws: a failing presence check is '
        'reported in detail', () async {
      // The probe says healthy but the keystore locks between it and the
      // attributes-only presence check. Diagnostics must degrade, not raise.
      final src = SystemKeySource(service: 'svc', api: _ExistsFailsApi());
      final status = await src.describe(); // must not throw
      expect(status.present, isFalse);
      expect(status.available, isTrue);
      expect(status.detail, contains('locked during presence check'));
    });
  });
}

/// A key exists, but fetching its value would be an error for diagnostics.
class _GetMustNotBeCalledApi extends FakeKeystoreApi {
  @override
  Future<bool> exists(String service, String account) async => true;

  @override
  Future<Uint8List?> get(String service, String account) async {
    throw StateError('describe() must not read the key value');
  }
}

/// Probe reports healthy, but the attributes-only presence check fails.
class _ExistsFailsApi extends FakeKeystoreApi {
  @override
  Future<bool> exists(String service, String account) async {
    throw const KeystoreLocked('locked during presence check');
  }
}

// dart:io used via Directory/File above.
