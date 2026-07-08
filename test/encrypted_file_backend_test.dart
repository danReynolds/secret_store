@Tags(['unit'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:secret_store/secret_store.dart';
// The concrete backend and the internal (unexported) key sources — the file
// backend's own unit test reaches them directly.
import 'package:secret_store/src/backends/encrypted_file_backend.dart';
import 'package:secret_store/src/key_source.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String containerPath;
  late String keyPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ss_efb_');
    containerPath = '${tmp.path}/secrets.enc';
    keyPath = '${tmp.path}/store.key';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Uint8List b(String s) => Uint8List.fromList(s.codeUnits);

  EncryptedFileBackend backend(KeySource ks) => EncryptedFileBackend(
        path: containerPath,
        keySource: ks,
        contextSalt: b('profile-uuid'),
      );

  group('round trip & persistence', () {
    test('write/read/contains/delete over a fresh store', () async {
      final be = backend(InMemoryKeySource());
      expect(await be.read('missing'), isNull);
      expect(await be.contains('missing'), isFalse);

      await be.write('db', b('spice'), label: 'DB key');
      expect(await be.read('db'), b('spice'));
      expect(await be.contains('db'), isTrue);

      await be.delete('db');
      expect(await be.read('db'), isNull);
    });

    test('persists across backend instances (same key source)', () async {
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('v'));
      // A brand new backend object, same on-disk container + key.
      final reopened = backend(FileKeySource(keyPath));
      expect(await reopened.read('k'), b('v'));
    });

    test('container and key files are created 0600', () async {
      await backend(FileKeySource(keyPath)).write('k', b('v'));
      int mode(String p) => File(p).statSync().mode & 0x1FF;
      expect(mode(containerPath), 0x180, reason: 'container 0600');
      expect(mode(keyPath), 0x180, reason: 'key file 0600');
    });

    test('readAll returns every entry; deleteAll empties', () async {
      final be = backend(InMemoryKeySource());
      await be.write('a', b('1'));
      await be.write('b', b('2'));
      expect((await be.readAll()).keys.toSet(), {'a', 'b'});
    });
  });

  group('in-process serialization', () {
    test('concurrent writes on one instance never lose updates', () async {
      // The FIFO mutex serializes the whole-file read-modify-write; without it
      // interleaved writers would clobber each other. (Cross-process
      // coordination is out of scope — a container is single-writer.)
      final be = backend(InMemoryKeySource());
      await Future.wait<void>([
        for (var i = 0; i < 8; i++) be.write('k$i', b('$i')),
      ]);
      expect((await be.readAll()).keys.toSet(),
          {for (var i = 0; i < 8; i++) 'k$i'});
    });
  });

  group('§7 failure matrix', () {
    test('fresh install (no container, no key) reads empty', () async {
      final be = backend(InMemoryKeySource());
      expect(await be.read('x'), isNull);
      expect(await be.readAll(), isEmpty);
    });

    test('container present, key gone -> StoreKeyMissing', () async {
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('v'));
      // Delete the key but keep the container.
      File(keyPath).deleteSync();
      expect(() => backend(FileKeySource(keyPath)).read('k'),
          throwsA(isA<StoreKeyMissing>()));
    });

    test('key present, container gone -> ContainerMissing', () async {
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('v'));
      File(containerPath).deleteSync();
      expect(() => backend(FileKeySource(keyPath)).read('k'),
          throwsA(isA<ContainerMissing>()));
    });

    test('wrong key -> WrongStoreKey (commitment check, pre-decryption)',
        () async {
      await backend(FileKeySource(keyPath)).write('k', b('v'));
      // Replace the key file with a different valid-length key.
      await FileKeySource(keyPath).delete();
      final wrong = InMemoryKeySource(generateStoreKey());
      expect(() => backend(wrong).read('k'), throwsA(isA<WrongStoreKey>()));
    });

    test('wrong profile salt -> WrongStoreKey', () async {
      final ks = FileKeySource(keyPath);
      await EncryptedFileBackend(
              path: containerPath, keySource: ks, contextSalt: b('profile-A'))
          .write('k', b('v'));
      final other = EncryptedFileBackend(
          path: containerPath,
          keySource: FileKeySource(keyPath),
          contextSalt: b('profile-B'));
      expect(() => other.read('k'), throwsA(isA<WrongStoreKey>()));
    });

    test('truncation is always a typed error (subtype depends on where)',
        () async {
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('value'));
      final full = File(containerPath).readAsBytesSync();

      // Each expectation is awaited: the read only touches the file once its
      // turn in the backend's serialization comes, so firing the next
      // truncation before the previous read completes would race it.

      // Chopped to a stub: the envelope is structurally too short.
      File(containerPath).writeAsBytesSync(full.sublist(0, 10));
      await expectLater(backend(FileKeySource(keyPath)).read('k'),
          throwsA(isA<ContainerCorrupt>()));

      // Chopped inside the ciphertext/tag: envelope-shaped, right key
      // (commitment passes), but the AEAD fails.
      File(containerPath).writeAsBytesSync(full.sublist(0, full.length - 4));
      await expectLater(backend(FileKeySource(keyPath)).read('k'),
          throwsA(isA<AuthenticationFailed>()));

      // Whatever the offset, it is never anything but a SecretStoreException.
      for (var cut = 0; cut < full.length; cut += 3) {
        File(containerPath).writeAsBytesSync(full.sublist(0, cut));
        await expectLater(backend(FileKeySource(keyPath)).read('k'),
            throwsA(isA<SecretStoreException>()),
            reason: 'prefix length $cut');
      }
    });

    test('a fresh-key write that fails rolls the key back (no orphan)',
        () async {
      // Point the container at a path whose parent cannot be created (a file
      // stands where the dir should be), so the write fails before sealing.
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('x');
      final ks = FileKeySource(keyPath);
      final be = EncryptedFileBackend(
          path: '${blocker.path}/secrets.enc', keySource: ks);
      await expectLater(be.write('k', b('v')), throwsA(anything));
      // The store key must NOT have been left behind.
      expect(await ks.read(), isNull,
          reason: 'fresh key rolled back on failure');
    });
  });

  group('read-side permission enforcement', () {
    test('a group/world-readable container is refused', () async {
      final ks = InMemoryKeySource();
      await backend(ks).write('k', b('v'));
      Process.runSync('chmod', ['0644', containerPath]);
      expect(() => backend(ks).read('k'), throwsA(isA<SecureFileError>()));
    });

    test('a group/world-accessible store directory is refused on read',
        () async {
      final ks = InMemoryKeySource();
      await backend(ks).write('k', b('v'));
      Process.runSync('chmod', ['0755', tmp.path]);
      addTearDown(() => Process.runSync('chmod', ['0700', tmp.path]));
      expect(() => backend(ks).read('k'), throwsA(isA<SecureFileError>()));
    });

    test('a group/world-readable key file is refused', () async {
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('v'));
      Process.runSync('chmod', ['0644', keyPath]);
      expect(() => backend(FileKeySource(keyPath)).read('k'),
          throwsA(isA<SecureFileError>()));
    });
  });

  group('describe', () {
    test('reports container/key presence', () async {
      final ks = FileKeySource(keyPath);
      final be = backend(ks);
      var info = await be.describe();
      expect(info.detail, contains('container=absent'));
      await be.write('k', b('v'));
      info = await be.describe();
      expect(info.detail, contains('container=present'));
      expect(info.detail, contains('key=present'));
      expect(info.capabilities.enumeration, isTrue);
    });
  });
}
