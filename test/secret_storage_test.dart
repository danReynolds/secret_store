@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';
// Validation and path derivation are internal (not exported); the front-API
// test reaches them directly.
import 'package:keybay/src/app_paths.dart';
import 'package:keybay/src/identifiers.dart';
import 'package:test/test.dart';

void main() {
  // Front-API tests use an in-memory-only fake backend (no disk, no crypto);
  // the real EncryptedFileBackend is exercised in its own test file.
  SecretStorage memStore() => SecretStorage.withBackend(_MemBackend());

  group('appId (the one input — traversal-proof by construction)', () {
    test('accepts reverse-DNS and simple ids', () {
      for (final ok in ['com.example.myapp', 'myapp', 'my-app_2', 'a']) {
        validateAppId(ok); // must not throw
      }
    });

    test('rejects path separators, dot-segments, and empties', () {
      for (final bad in [
        '', // empty
        '..', // parent segment
        '.', // self segment
        '...', // dots-only (no alphanumeric)
        '../x', // traversal (contains '/')
        'a/../b', // traversal (contains '/')
        '/abs', // absolute (contains '/')
        'a/b', // any '/' at all
        'x' * 121, // over-long
        'has space',
      ]) {
        expect(() => validateAppId(bad), throwsA(isA<ArgumentError>()),
            reason: '"$bad" must be rejected');
      }
    });

    test('the constructor validates appId before touching any platform API',
        () {
      expect(() => SecretStorage(appId: '../escape'),
          throwsA(isA<ArgumentError>()));
    });

    test('the macOS DP-probe service is unrepresentable as an appId', () {
      // The DP probe uses a fixed internal service containing a space so it can
      // never collide with — and then delete — a caller's item. This asserts
      // the invariant that keeps that true: no appId can equal that service.
      // The string mirrors the FROZEN `_dpProbeService` constant in
      // lib/src/ffi/keychain.dart (predates the keybay rename) verbatim.
      expect(() => validateAppId('secret_store dp-probe'),
          throwsA(isA<ArgumentError>()));
    });

    test('derived container path stays inside the data dir for this host', () {
      // Host-dependent by design (runs on both CI OSes): the path must end
      // with <appId>/secrets.enc and contain no traversable segments.
      final p = containerPathFor('com.example.demo');
      expect(p, endsWith('/com.example.demo/secrets.enc'));
      expect(p.split('/'), isNot(contains('..')));
      expect(p, startsWith('/'), reason: 'absolute path');
    });
  });

  group('bytes/string API', () {
    test('write/read round-trips bytes and strings', () async {
      final s = memStore();
      await s.write('k', Uint8List.fromList([1, 2, 3]));
      expect(await s.read('k'), [1, 2, 3]);

      await s.writeString('url', 'https://example/invite#abc');
      expect(await s.readString('url'), 'https://example/invite#abc');
    });

    test('readString decodes UTF-8', () async {
      final s = memStore();
      await s.write('u', Uint8List.fromList(utf8.encode('café ☕')));
      expect(await s.readString('u'), 'café ☕');
    });

    test('containsKey / delete', () async {
      final s = memStore();
      expect(await s.containsKey('k'), isFalse);
      await s.write('k', Uint8List.fromList([1]));
      expect(await s.containsKey('k'), isTrue);
      await s.delete('k');
      expect(await s.containsKey('k'), isFalse);
    });
  });

  group('identifier validation', () {
    test('rejects out-of-charset keys (injection defense)', () async {
      final s = memStore();
      for (final bad in ['has space', 'new\nline', 'semi;colon', r'$(x)', '']) {
        expect(() => s.read(bad), throwsA(isA<ArgumentError>()),
            reason: 'key "$bad" must be rejected');
      }
    });

    test('accepts the identifier charset', () async {
      final s = memStore();
      for (final ok in ['dune_db_key', 'a.b', 'dune/uuid-123', 'client_id']) {
        await s.write(ok, Uint8List.fromList([1]));
        expect(await s.read(ok), [1]);
      }
    });

    test('rejects control characters in a label, allows spaces', () async {
      final s = memStore();
      expect(() => s.write('k', Uint8List.fromList([1]), label: 'bad\u0000'),
          throwsA(isA<ArgumentError>()));
      await s.write('k', Uint8List.fromList([1]), label: 'Dune database key');
    });
  });

  group('enumeration capability', () {
    test('readAll works when supported', () async {
      final s = memStore();
      await s.write('a', Uint8List.fromList([1]));
      await s.write('b', Uint8List.fromList([2]));
      expect((await s.readAll()).keys.toSet(), {'a', 'b'});
      await s.deleteAll();
      expect(await s.readAll(), isEmpty);
    });

    test('readAll throws UnsupportedCapability when not supported', () async {
      final s = SecretStorage.withBackend(_NoEnumBackend());
      expect(s.readAll, throwsA(isA<UnsupportedCapability>()));
    });
  });
}

/// Minimal in-memory backend for front-API tests (no disk, no crypto).
class _MemBackend implements SecretBackend {
  final Map<String, Uint8List> _m = {};

  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: true, persistent: false);

  @override
  Future<Uint8List?> read(String key) async => _m[key];

  @override
  Future<bool> contains(String key) async => _m.containsKey(key);

  @override
  Future<void> write(String key, Uint8List value, {String? label}) async =>
      _m[key] = value;

  @override
  Future<void> delete(String key) async => _m.remove(key);

  @override
  Future<Map<String, Uint8List>> readAll() async => Map.of(_m);

  @override
  Future<BackendInfo> describe() async => const BackendInfo(
        scheme: StorageScheme.encryptedFile,
        available: true,
        locked: false,
        capabilities: BackendCapabilities(enumeration: true, persistent: false),
      );
}

class _NoEnumBackend extends _MemBackend {
  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: false, persistent: true);
}
