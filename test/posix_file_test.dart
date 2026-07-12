@Tags(['unit'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:keyway/src/ffi/posix_file.dart';
import 'package:test/test.dart';

/// These run on the real filesystem (hermetic under a temp dir) and prove the
/// POSIX shim delivers what dart:io cannot: 0600-from-birth, atomic replace
/// (including over a pre-planted destination symlink, which is replaced rather
/// than written through), rejection of non-regular files (a FIFO), private
/// directories, and the read cap. Two properties are covered by inspection
/// rather than assertion: the fsync-before-rename ordering (not observable
/// in-process without a syscall-counting seam, which is disproportionate surface
/// for the security-critical file shim) and O_EXCL refusal at the *temp* path
/// (whose name is randomized, so a collision can't be planted deterministically).
void main() {
  late Directory tmp;
  const fs = SecureFileSystem();

  setUp(() => tmp = Directory.systemTemp.createTempSync('ss_posix_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  int mode(String path) => File(path).statSync().mode & 0x1FF;

  test('writeAtomicSync creates the file mode 0600 (not 0644)', () {
    final p = '${tmp.path}/secret.bin';
    fs.writeAtomicSync(p, Uint8List.fromList([1, 2, 3, 4]));
    expect(mode(p), 0x180,
        reason: '0600 expected, got ${mode(p).toRadixString(8)}');
    expect(File(p).readAsBytesSync(), [1, 2, 3, 4]);
  });

  test('overwrites atomically and leaves no temp files', () {
    final p = '${tmp.path}/secret.bin';
    fs.writeAtomicSync(p, Uint8List.fromList([1]));
    fs.writeAtomicSync(p, Uint8List.fromList([2, 2]));
    expect(File(p).readAsBytesSync(), [2, 2]);
    expect(mode(p), 0x180);
    final leftovers =
        tmp.listSync().whereType<File>().where((f) => f.path.contains('.tmp.'));
    expect(leftovers, isEmpty,
        reason: 'temp files must be renamed or cleaned up');
  });

  test('a destination symlink is replaced, not written through (anti-clobber)',
      () {
    // If an attacker pre-plants a symlink at the container path pointing outside
    // the private dir, the atomic rename replaces the symlink with our real
    // file — the symlink's target is never written. (The write goes to an
    // O_EXCL temp, then rename(2) over the destination path, which does not
    // follow a symlink there.)
    final outside = '${tmp.path}/outside_target';
    File(outside).writeAsStringSync('DO-NOT-CLOBBER');
    final dest = '${tmp.path}/secrets.enc';
    Link(dest).createSync(outside);
    fs.writeAtomicSync(dest, Uint8List.fromList([7, 7, 7]));
    expect(File(outside).readAsStringSync(), 'DO-NOT-CLOBBER',
        reason: 'the symlink target must be untouched');
    expect(FileSystemEntity.isLinkSync(dest), isFalse,
        reason: 'the symlink was replaced by a real regular file');
    expect(File(dest).readAsBytesSync(), [7, 7, 7]);
  });

  test('empty payload round-trips at 0600', () {
    final p = '${tmp.path}/empty.bin';
    fs.writeAtomicSync(p, Uint8List(0));
    expect(mode(p), 0x180);
    expect(File(p).readAsBytesSync(), isEmpty);
  });

  test('readCappedSync returns null for missing, enforces the cap', () {
    final p = '${tmp.path}/x.bin';
    expect(fs.readCappedSync(p, maxBytes: 10), isNull);
    fs.writeAtomicSync(p, Uint8List.fromList(List.filled(20, 7)));
    expect(() => fs.readCappedSync(p, maxBytes: 10),
        throwsA(isA<SecureFileError>()));
    expect(fs.readCappedSync(p, maxBytes: 100), hasLength(20));
  });

  test('ensurePrivateDirSync creates 0700 and accepts it', () {
    final d = '${tmp.path}/state';
    fs.ensurePrivateDirSync(d);
    expect(mode(d), 0x1C0,
        reason: '0700 expected, got ${mode(d).toRadixString(8)}');
    // idempotent
    fs.ensurePrivateDirSync(d);
  });

  test('ensurePrivateDirSync rejects a world/group-accessible dir', () {
    final d = Directory('${tmp.path}/loose')..createSync();
    Process.runSync('chmod', ['0755', d.path]);
    expect(
        () => fs.ensurePrivateDirSync(d.path), throwsA(isA<SecureFileError>()));
  });

  test('ensurePrivateDirSync creates missing ancestors, each 0700', () {
    // The clean-account case: none of these exist yet (cf. ~/.local/share/<app>).
    final leaf = '${tmp.path}/a/b/c';
    fs.ensurePrivateDirSync(leaf);
    for (final d in ['${tmp.path}/a', '${tmp.path}/a/b', leaf]) {
      expect(mode(d), 0x1C0,
          reason: '0700 expected for $d, got ${mode(d).toRadixString(8)}');
    }
  });

  test('delete is idempotent', () {
    final p = '${tmp.path}/gone.bin';
    fs.deleteSync(p); // no throw on missing
    fs.writeAtomicSync(p, Uint8List.fromList([1]));
    fs.deleteSync(p);
    expect(File(p).existsSync(), isFalse);
  });

  group('readCappedSync hardening', () {
    test('requirePrivate refuses a group/world-readable file', () {
      final p = '${tmp.path}/loose.bin';
      fs.writeAtomicSync(p, Uint8List.fromList([1, 2]));
      expect(fs.readCappedSync(p, maxBytes: 10, requirePrivate: true),
          [1, 2]); // 0600 passes
      Process.runSync('chmod', ['0644', p]);
      expect(() => fs.readCappedSync(p, maxBytes: 10, requirePrivate: true),
          throwsA(isA<SecureFileError>()));
      // Without the flag the loose file is still readable (generic primitive).
      expect(fs.readCappedSync(p, maxBytes: 10), [1, 2]);
    });

    test('refuses a non-regular file (a FIFO would block a read forever)', () {
      // Both a directory and a FIFO are non-regular; the guard rejects each
      // before any read. The FIFO is the security-relevant case: opening one
      // for read blocks until a writer appears, so a naive reader at a planted
      // FIFO path would hang forever. (A FIFO stats as `pipe`, not `file`.)
      final d = Directory('${tmp.path}/adir')..createSync();
      expect(() => fs.readCappedSync(d.path, maxBytes: 10),
          throwsA(isA<SecureFileError>()));

      final fifo = '${tmp.path}/a.fifo';
      expect(Process.runSync('mkfifo', [fifo]).exitCode, 0,
          reason: 'mkfifo should succeed on this POSIX host');
      expect(() => fs.readCappedSync(fifo, maxBytes: 10),
          throwsA(isA<SecureFileError>()));
    });
  });

  group('verifyPrivateDirSync', () {
    test('absent -> false; 0700 -> true; loose -> throws', () {
      final d = '${tmp.path}/v';
      expect(fs.verifyPrivateDirSync(d), isFalse);
      fs.ensurePrivateDirSync(d);
      expect(fs.verifyPrivateDirSync(d), isTrue);
      Process.runSync('chmod', ['0755', d]);
      expect(() => fs.verifyPrivateDirSync(d), throwsA(isA<SecureFileError>()));
    });
  });

  group('withExclusiveLock (advisory flock)', () {
    test('serializes overlapping holders on separate descriptors', () async {
      // Five holders acquired concurrently, each opening its OWN descriptor on
      // the same lock file. flock is per-open-file-description, so even within
      // one isolate they must not overlap — this is exactly the property that
      // extends to separate isolates and processes.
      final lockPath = '${tmp.path}/x.lock';
      var active = 0;
      var maxActive = 0;
      Future<void> hold() => fs.withExclusiveLock(
            lockPath,
            timeout: const Duration(seconds: 5),
            body: () async {
              active++;
              maxActive = active > maxActive ? active : maxActive;
              await Future<void>.delayed(const Duration(milliseconds: 15));
              active--;
            },
          );
      await Future.wait([for (var i = 0; i < 5; i++) hold()]);
      expect(maxActive, 1,
          reason: 'flock must prevent overlapping critical sections');
      // The lock file persists as an empty 0600 marker (never renamed/removed).
      expect(File(lockPath).existsSync(), isTrue);
      expect(mode(lockPath), 0x180);
    });

    test('returns the body result and frees the lock for the next caller',
        () async {
      final lockPath = '${tmp.path}/y.lock';
      final first = await fs.withExclusiveLock(lockPath,
          timeout: const Duration(seconds: 5), body: () async => 42);
      expect(first, 42);
      // Would deadlock/timeout if the first call hadn't released the lock.
      final second = await fs.withExclusiveLock(lockPath,
          timeout: const Duration(seconds: 5), body: () async => 'ok');
      expect(second, 'ok');
    });

    test('releases the lock even when the body throws', () async {
      final lockPath = '${tmp.path}/z.lock';
      await expectLater(
        fs.withExclusiveLock<void>(lockPath,
            timeout: const Duration(seconds: 5),
            body: () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      final ok = await fs
          .withExclusiveLock(lockPath,
              timeout: const Duration(seconds: 5), body: () async => true)
          .timeout(const Duration(seconds: 2));
      expect(ok, isTrue, reason: 'the lock must be freed on the error path');
    });

    test('times out as StoreBusy while a peer holds the lock', () async {
      final lockPath = '${tmp.path}/busy.lock';
      final held = Completer<void>();
      final release = Completer<void>();
      final holder = fs.withExclusiveLock(lockPath,
          timeout: const Duration(seconds: 5), body: () async {
        held.complete();
        await release.future;
      });
      await held.future;
      await expectLater(
        fs.withExclusiveLock(lockPath,
            timeout: const Duration(milliseconds: 80), body: () async => 1),
        throwsA(isA<StoreBusy>()),
      );
      release.complete();
      await holder;
    });
  });
}
