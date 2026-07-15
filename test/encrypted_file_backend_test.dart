@Tags(['unit'])
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';
// The concrete backend and the internal (unexported) key sources — the file
// backend's own unit test reaches them directly. (SecureFileError is now in
// the public taxonomy, so it comes from the barrel above.)
import 'package:keybay/src/backends/encrypted_file_backend.dart';
import 'package:keybay/src/ffi/posix_file.dart';
import 'package:keybay/src/key_source.dart';
import 'package:test/test.dart';

/// A filesystem whose atomic write always fails (everything else is real), used
/// to drive the container-write failure path — notably the fresh-key rollback.
class _WriteFailsFs extends SecureFileSystem {
  const _WriteFailsFs();
  @override
  void writeAtomicSync(String path, Uint8List bytes) {
    throw SecureFileError('write', path, 28); // simulate ENOSPC mid-write
  }
}

void main() {
  late Directory tmp;
  late String containerPath;
  late String keyPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ss_efb_');
    // createTempSync respects umask (0755 on Linux, 0700 on macOS's per-user
    // /var/folders). A real store directory is private, and the backend
    // enforces that — so the fixture must start private too, or every write
    // is (correctly) rejected on Linux before its assertion. The
    // permission-enforcement group below re-loosens perms on purpose.
    Process.runSync('chmod', ['700', tmp.path]);
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
      // interleaved writers in this isolate would clobber each other. (The
      // cross-isolate/cross-process case is covered by the flock group below.)
      final be = backend(InMemoryKeySource());
      await Future.wait<void>([
        for (var i = 0; i < 8; i++) be.write('k$i', b('$i')),
      ]);
      expect((await be.readAll()).keys.toSet(),
          {for (var i = 0; i < 8; i++) 'k$i'});
    });

    test('two backends on the same path also serialize (per-path lock)',
        () async {
      // Two SecretStorage/backend objects for one store must share the lock or
      // their interleaved read-modify-writes drop updates. Shared key source →
      // same store key, so both read/write the same container.
      final ks = InMemoryKeySource();
      final be1 = backend(ks);
      final be2 = backend(ks);
      await Future.wait<void>([
        for (var i = 0; i < 12; i++)
          (i.isEven ? be1 : be2).write('k$i', b('$i')),
      ]);
      expect((await be1.readAll()).keys.toSet(),
          {for (var i = 0; i < 12; i++) 'k$i'});
    });
  });

  group('cross-isolate serialization (advisory flock)', () {
    test('concurrent writers in separate isolates never lose an update',
        () async {
      // The isolate-local FIFO mutex cannot coordinate SEPARATE isolates — each
      // has its own. Only the on-disk flock does. Four isolates, each with its
      // own EncryptedFileBackend + FileKeySource on the SAME container and key
      // file, hammer distinct keys. Without the flock this races two ways: lost
      // read-modify-writes (fewer keys survive), or — on the very first write —
      // two isolates minting different store keys and leaving the container
      // sealed under a discarded one (WrongStoreKey on reopen). With it, every
      // write from every isolate must land.
      const writers = 4;
      const perWriter = 20;
      final salt = b('profile-uuid');
      final replies = ReceivePort();
      final spawned = <Future<Isolate>>[];
      for (var w = 0; w < writers; w++) {
        spawned.add(Isolate.spawn(
          _writerIsolate,
          _WriterConfig(
              replies.sendPort, containerPath, keyPath, salt, 'w$w', perWriter),
        ));
      }
      final errors = <String>[];
      var done = 0;
      await for (final msg in replies) {
        if (msg is String) errors.add(msg); // an isolate reported a failure
        if (++done == writers) break;
      }
      replies.close();
      for (final s in spawned) {
        (await s).kill(priority: Isolate.immediate);
      }
      expect(errors, isEmpty,
          reason: 'an isolate failed while writing: $errors');

      final all = await backend(FileKeySource(keyPath)).readAll();
      expect(all, hasLength(writers * perWriter),
          reason: 'every write from every isolate must survive');
      for (var w = 0; w < writers; w++) {
        for (var i = 0; i < perWriter; i++) {
          final name = 'w$w-$i';
          expect(all[name], Uint8List.fromList(name.codeUnits),
              reason: 'missing or wrong value for $name');
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('size cap', () {
    test('an oversized value is rejected; the existing store stays intact',
        () async {
      final be = backend(InMemoryKeySource());
      await be.write('keep', b('precious'));
      final huge = Uint8List(maxContainerBytes + 1);
      await expectLater(be.write('huge', huge), throwsA(isA<StoreTooLarge>()));
      // The prior container was never replaced — all entries remain readable.
      expect(await be.read('keep'), b('precious'));
      expect(await be.read('huge'), isNull);
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

    test('key present, container gone -> ContainerMissing (read is loud)',
        () async {
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('v'));
      File(containerPath).deleteSync();
      expect(() => backend(FileKeySource(keyPath)).read('k'),
          throwsA(isA<ContainerMissing>()));
    });

    test('key present, container gone -> write() heals the orphan, not wedged',
        () async {
      // Simulates the crash window between store-key creation and the first
      // container write: the key exists, the container does not. A mutating
      // op must re-seal under the existing key instead of throwing
      // ContainerMissing forever (which would brick the store).
      final ks = FileKeySource(keyPath);
      await backend(ks).write('k', b('v'));
      File(containerPath).deleteSync();
      await backend(FileKeySource(keyPath)).write('k2', b('v2'));
      final reopened = backend(FileKeySource(keyPath));
      expect(await reopened.read('k2'), b('v2'), reason: 'store usable again');
      expect(await reopened.read('k'), isNull, reason: 'lost data stays lost');
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
      // Fail the container write *after* a fresh key is minted (an injected fs
      // whose writeAtomicSync throws; everything else real), so _save's
      // rollback path actually runs. InMemoryKeySource keeps the only
      // writeAtomicSync in the flow the container write itself — a FileKeySource
      // would write the key through the same failing fs and never reach _save.
      // (The prior version aimed the container at an uncreatable parent dir,
      // which threw in ensurePrivateDirSync *before* any key was created, so it
      // asserted nothing about rollback — and matched throwsA(anything).)
      final ks = InMemoryKeySource();
      final be = EncryptedFileBackend(
        path: containerPath,
        keySource: ks,
        contextSalt: b('profile-uuid'),
        fs: const _WriteFailsFs(),
      );
      await expectLater(be.write('k', b('v')), throwsA(isA<SecureFileError>()));
      // The freshly-minted store key must NOT have been left behind.
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

/// Message for [_writerIsolate]: every field is isolate-sendable (a [SendPort],
/// strings, a byte list, ints).
class _WriterConfig {
  const _WriterConfig(this.reply, this.containerPath, this.keyPath, this.salt,
      this.prefix, this.count);
  final SendPort reply;
  final String containerPath;
  final String keyPath;
  final List<int> salt;
  final String prefix;
  final int count;
}

/// A spawned writer: writes `count` distinct keys (`<prefix>-0…`) to a shared
/// container + key file through its own backend, then reports back — `null` on
/// success, the error string on failure — so the parent can assert no isolate
/// raised (e.g. a WrongStoreKey from a first-write key race).
Future<void> _writerIsolate(_WriterConfig c) async {
  final be = EncryptedFileBackend(
    path: c.containerPath,
    keySource: FileKeySource(c.keyPath),
    contextSalt: c.salt,
  );
  try {
    for (var i = 0; i < c.count; i++) {
      final name = '${c.prefix}-$i';
      await be.write(name, Uint8List.fromList(name.codeUnits));
    }
    c.reply.send(null);
  } catch (e) {
    c.reply.send('$e');
  }
}
