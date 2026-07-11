/// A minimal POSIX file shim (see doc/design.md).
///
/// `dart:io` cannot create a file with restrictive permissions from birth (no
/// umask/chmod/fchmod), cannot `fsync`, and cannot exclusive-create —
/// verified: `File.writeAsBytes` yields mode 0644. For key material
/// that is unacceptable, so writes go through libc directly:
/// `open(O_CREAT|O_EXCL|O_WRONLY, 0600)` → write → `fsync` → `close` → atomic
/// `rename` → best-effort directory `fsync`. This is a second, deliberately
/// tiny FFI locus (the first being the macOS Keychain binding); it is the
/// safest category of FFI — fixed-arity libc calls over ints and byte buffers.
///
/// Native staging buffers that held secret bytes are zeroed before they are
/// returned to the allocator: unlike Dart-heap memory, FFI memory *can* be
/// scrubbed, so it is.
///
/// POSIX-only. macOS and Linux share these libc symbols; the open() flag values
/// differ by platform and are selected below.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// --- libc bindings -----------------------------------------------------------

final DynamicLibrary _libc = DynamicLibrary.process();

// open() is variadic in C (`int open(const char*, int, ...)`). The mode MUST be
// bound as a vararg: on Apple arm64 variadic arguments are passed on the stack,
// not in registers, so a fixed 3-argument binding silently passes mode where
// open never reads it — yielding a mode-000 file. `VarArgs` marshals it
// correctly. (Verified: the fixed binding produced 0o000; VarArgs produces
// 0o600. The perms test guards this permanently.)
final int Function(Pointer<Utf8>, int, int) _open = _libc.lookupFunction<
    Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
    int Function(Pointer<Utf8>, int, int)>('open');

final int Function(int, Pointer<Uint8>, int) _write = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');

final int Function(int) _fsync =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');

final int Function(int) _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

// mkdir(const char*, mode_t). mode_t is uint16 (macOS) / uint32 (Linux); a
// Uint32 binding is correct on both (macOS reads the low 16 bits).
final int Function(Pointer<Utf8>, int) _mkdir = _libc.lookupFunction<
    Int32 Function(Pointer<Utf8>, Uint32),
    int Function(Pointer<Utf8>, int)>('mkdir');

// errno location differs by libc: __error() on macOS/BSD, __errno_location()
// on glibc/musl, __errno() on Android bionic. Resolve by trying the platform's
// candidates in order — a fixed guess would turn every filesystem error on the
// odd-one-out (e.g. Android, now that the file backend runs there) into an
// untyped symbol-lookup failure instead of a typed SecureFileError.
final Pointer<Int32> Function() _errnoLocation = _resolveErrnoLocation();

Pointer<Int32> Function() _resolveErrnoLocation() {
  final candidates = Platform.isMacOS
      ? const ['__error']
      : const ['__errno_location', '__errno']; // glibc/musl, then bionic
  for (final symbol in candidates) {
    try {
      return _libc.lookupFunction<Pointer<Int32> Function(),
          Pointer<Int32> Function()>(symbol);
    } on ArgumentError {
      // not this libc's spelling — try the next
    }
  }
  throw UnsupportedError(
      'no errno-location symbol (${candidates.join('/')}) found in libc');
}

int get _errno => _errnoLocation().value;

// open() flags — values differ between Linux and macOS/BSD.
const int _oRdOnly = 0x0000;
final int _oWrOnly = 0x0001;
final int _oCreat = Platform.isMacOS ? 0x0200 : 0x40;
final int _oExcl = Platform.isMacOS ? 0x0800 : 0x80;

const int _eIntr = 4;

/// Thrown when a low-level file operation fails. Carries the operation and the
/// path — never file contents.
final class SecureFileError implements Exception {
  SecureFileError(this.operation, this.path, this.errno);
  final String operation;
  final String path;
  final int errno;
  @override
  String toString() => 'SecureFileError($operation "$path"): errno $errno';
}

/// Secure file primitives for the encrypted-file backend and file key source.
class SecureFileSystem {
  const SecureFileSystem();

  /// Writes [bytes] to [path] atomically and privately: an exclusive-created
  /// `0600` temp file in the same directory, fsync'd, then renamed over
  /// [path], then a best-effort fsync of the directory so the rename itself
  /// survives a power cut. A crash leaves either the previous file or the new
  /// one — never a torn mix. The temp file is unlinked on any failure.
  void writeAtomicSync(String path, Uint8List bytes) {
    final dir = File(path).parent.path;
    // Random suffix so a stale/pre-placed temp can't collide, and O_EXCL means
    // creation fails rather than following a planted file/symlink.
    final tmp = '$dir/.${_baseName(path)}.tmp.${_randomSuffix()}';
    final tmpPtr = tmp.toNativeUtf8();
    final fd = _open(tmpPtr, _oWrOnly | _oCreat | _oExcl, 0x180 /* 0600 */);
    if (fd < 0) {
      final e = _errno;
      malloc.free(tmpPtr);
      throw SecureFileError('open', tmp, e);
    }
    final bufLen = bytes.isEmpty ? 1 : bytes.length;
    final buf = malloc<Uint8>(bufLen);
    try {
      if (bytes.isNotEmpty) buf.asTypedList(bytes.length).setAll(0, bytes);
      var written = 0;
      while (written < bytes.length) {
        final n = _write(fd, buf + written, bytes.length - written);
        if (n < 0) {
          final e = _errno;
          if (e == _eIntr) continue;
          throw SecureFileError('write', tmp, e);
        }
        written += n;
      }
      if (_fsync(fd) < 0) {
        throw SecureFileError('fsync', tmp, _errno);
      }
    } catch (_) {
      _close(fd);
      _tryUnlink(tmp);
      rethrow;
    } finally {
      // Scrub the staging copy before returning it to the allocator — for the
      // file key source it holds raw key material.
      buf.asTypedList(bufLen).fillRange(0, bufLen, 0);
      malloc.free(buf);
      malloc.free(tmpPtr);
    }
    if (_close(fd) < 0) {
      final e = _errno;
      _tryUnlink(tmp);
      throw SecureFileError('close', tmp, e);
    }
    // Atomic same-directory rename (POSIX guarantees it). Dart's rename maps to
    // rename(2). On failure, drop the temp so we don't litter.
    try {
      File(tmp).renameSync(path);
    } catch (_) {
      _tryUnlink(tmp);
      rethrow;
    }
    _fsyncDirBestEffort(dir);
  }

  /// Reads [path], rejecting anything larger than [maxBytes] *before* reading
  /// the contents, and rejecting non-regular files (a FIFO at the path would
  /// otherwise block forever). With [requirePrivate], additionally refuses a
  /// group/other-accessible file (`mode & 0o077 != 0`) — the OpenSSH stance:
  /// secret material with loose permissions is an error, not a warning.
  /// Returns null if the file does not exist.
  Uint8List? readCappedSync(
    String path, {
    required int maxBytes,
    bool requirePrivate = false,
  }) {
    final f = File(path);
    final stat = f.statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    if (stat.type != FileSystemEntityType.file) {
      throw SecureFileError('read(not-a-regular-file)', path, 0);
    }
    if (requirePrivate && (stat.mode & 0x3F) != 0) {
      throw SecureFileError(
          'read(insecure-mode:${(stat.mode & 0x1FF).toRadixString(8)})',
          path,
          0);
    }
    if (stat.size > maxBytes) {
      throw SecureFileError('read(too-large:${stat.size}>$maxBytes)', path, 0);
    }
    return f.readAsBytesSync();
  }

  /// Deletes [path] if present. Idempotent.
  void deleteSync(String path) {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }

  /// Whether any filesystem entity exists at [path].
  bool existsSync(String path) =>
      File(path).statSync().type != FileSystemEntityType.notFound;

  /// Verifies that [dirPath] — if it exists — is a directory granting no
  /// group/other access (`mode & 0o077 == 0`). Returns false when absent,
  /// true when present and private; throws [SecureFileError] when present but
  /// loose or not a directory. Read paths use this: verify, never create.
  bool verifyPrivateDirSync(String dirPath) {
    final stat = Directory(dirPath).statSync();
    if (stat.type == FileSystemEntityType.notFound) {
      return false;
    }
    if (stat.type != FileSystemEntityType.directory) {
      throw SecureFileError('not-a-directory', dirPath, 0);
    }
    if ((stat.mode & 0x3F) != 0) {
      // 0x3F = 0o77 (group+other bits). Refuse a world/group-accessible dir.
      throw SecureFileError(
          'insecure-dir-mode(${(stat.mode & 0x1FF).toRadixString(8)})',
          dirPath,
          0);
    }
    return true;
  }

  /// Ensures [dirPath] exists as a directory that grants no group/other access
  /// (`mode & 0o077 == 0`). Creates it — and any missing ancestors — `0700` via
  /// `mkdir(2)` (unlike `Directory.createSync`, which respects umask and can
  /// yield 0755), then verifies the leaf — so a *pre-existing* world/group-
  /// accessible leaf is rejected, not silently trusted. The dir's privacy is
  /// the property the file backend's security rests on, so it is enforced, not
  /// assumed.
  ///
  /// Note (v1): the strict "owned by the current euid" check is deferred — it
  /// needs per-platform `struct stat` offsets. A 0700 directory owned by
  /// another user is unusable to us anyway (operations fail with EACCES), so
  /// the mode check carries the load. Tracked as a hardening follow-up.
  void ensurePrivateDirSync(String dirPath) {
    // Create the leaf and any missing ancestors, each 0700. A clean home may
    // lack `~/.local/share` (or a freshly-pointed `XDG_DATA_HOME`) entirely,
    // and the XDG spec says to create a missing data directory with mode 0700 —
    // so we do, with a *known* mode rather than refusing. Recursion stops at
    // the first existing ancestor (HOME at worst, which the resolver
    // guarantees), so we never walk above the intended base.
    _ensureDirChainSync(dirPath);
    if (!verifyPrivateDirSync(dirPath)) {
      // We just created it (or it pre-existed private), so absence/looseness
      // here means it vanished or was tampered under us.
      throw SecureFileError('dir-vanished', dirPath, 0);
    }
  }

  void _ensureDirChainSync(String dirPath) {
    final dir = Directory(dirPath);
    if (dir.existsSync()) return;
    final parent = dir.parent;
    if (parent.path != dirPath) _ensureDirChainSync(parent.path);
    final ptr = dirPath.toNativeUtf8();
    try {
      if (_mkdir(ptr, 0x1C0 /* 0700 */) < 0) {
        final e = _errno;
        if (e != 17 /* EEXIST: lost a race, fine */) {
          throw SecureFileError('mkdir', dirPath, e);
        }
      }
    } finally {
      malloc.free(ptr);
    }
  }

  /// Best-effort fsync of a directory so a completed rename is durable across
  /// a power cut (POSIX leaves rename persistence to the directory metadata).
  /// Failures are ignored: some filesystems reject fsync on a directory fd,
  /// and the write itself is already atomic — this only narrows the crash
  /// window, it cannot un-tear anything.
  void _fsyncDirBestEffort(String dirPath) {
    final ptr = dirPath.toNativeUtf8();
    try {
      final fd = _open(ptr, _oRdOnly, 0);
      if (fd >= 0) {
        _fsync(fd);
        _close(fd);
      }
    } finally {
      malloc.free(ptr);
    }
  }

  void _tryUnlink(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // best effort
    }
  }

  String _baseName(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}

// Non-crypto uniqueness for the temp name (O_EXCL provides the real safety).
int _tmpCounter = 0;
String _randomSuffix() =>
    '${pid}_${DateTime.now().microsecondsSinceEpoch}_${_tmpCounter++}';
