/// Encrypted-file backend: an authenticated container sealed by a store key
/// from a [KeySource] (see doc/design.md).
///
/// Implements the §7 failure matrix precisely, so a diagnostics UI can tell a
/// fresh install from a lost container, a lost key, a wrong key, or tampering.
///
/// **Concurrency.** Mutating whole-file read-modify-write operations are
/// serialized on two layers:
///
/// 1. A FIFO mutex keyed on the **container path**, so concurrent calls within
///    one isolate — even from two separate backend instances (e.g. two
///    `SecretStorage(appId:)` objects) targeting the same store — never
///    interleave and drop updates. It is an isolate-local static, so on its own
///    it does not coordinate across isolates or processes.
/// 2. An **exclusive advisory `flock`** on a dedicated `<container>.lock` file,
///    taken for the duration of every mutating operation. flock ownership is
///    per open file description, so it excludes *other isolates in the same
///    process* (which POSIX `fcntl` locks would not) **and** *other processes*
///    alike. This closes the two cross-writer hazards: a lost update, and — on
///    first write — two writers each minting a store key and leaving the
///    container sealed under a discarded one.
///
/// Reads are intentionally **not** locked: writes are atomic (temp + `rename`),
/// so a concurrent reader always sees either the whole old container or the
/// whole new one, never a torn mix. If a mutating peer holds the lock past a
/// ~10s timeout, the operation throws [StoreBusy] rather than blocking forever
/// (a crashed holder's lock is released by the OS when its fd closes, so a
/// timeout means a *live* wedged peer). The lock is advisory and needs a
/// filesystem that supports `flock`; every local app-data filesystem does. On a
/// rare one that doesn't (some network mounts return `ENOLCK`/`EOPNOTSUPP`), the
/// mutating operation **fails closed** with [SecureFileError] rather than
/// silently proceeding without the lock — a lost lock is a security downgrade,
/// so it is surfaced, not swallowed.
library;

import 'dart:async';
import 'dart:typed_data';

import '../backend.dart';
import '../container/container.dart';
import '../container/tlv.dart';
import '../errors.dart';
import '../ffi/posix_file.dart';
import '../key_source.dart';

/// On-disk cap for the container file, checked before the bytes are read. Three
/// orders of magnitude above any realistic store.
const int maxContainerBytes = 16 * 1024 * 1024;

final class EncryptedFileBackend implements SecretBackend {
  EncryptedFileBackend({
    required this.path,
    required KeySource keySource,
    List<int> contextSalt = const [],
    SecureFileSystem fs = const SecureFileSystem(),
  })  : _keySource = keySource,
        _fs = fs,
        _container = Container(contextSalt: contextSalt);

  /// Path to the container file. Its parent directory is ensured `0700`.
  final String path;

  final KeySource _keySource;
  final SecureFileSystem _fs;
  final Container _container;

  /// The advisory lock file guarding mutating access, beside the container. A
  /// stable, never-renamed marker (see the class doc's concurrency note).
  String get _lockPath => '$path.lock';

  /// Serialization is keyed by container path and shared across backend
  /// instances **within an isolate**: two backends for the same store in the
  /// same isolate must take the same lock or they can drop each other's
  /// whole-file updates. Statics are isolate-local, so this does not coordinate
  /// across isolates or processes (see the class doc). (Isolate-lifetime; one
  /// small entry per distinct store path.)
  static final Map<String, _TurnLock> _locks = {};
  _TurnLock get _mutex => _locks.putIfAbsent(path, _TurnLock.new);

  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: true, persistent: true);

  String get _parentDir {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '.' : path.substring(0, i);
  }

  /// Serializes [body]. Same-isolate siblings queue on the FIFO mutex; mutating
  /// (`exclusive`) operations additionally take the cross-isolate/cross-process
  /// `flock` for the duration of [body], after ensuring the private store
  /// directory (which must exist to hold the lock file). Reads only verify the
  /// directory and run lock-free — atomic writes make a read consistent without
  /// one.
  Future<T> _serialized<T>(
      {required bool exclusive, required Future<T> Function() body}) {
    return _mutex.run(() async {
      if (exclusive) {
        _fs.ensurePrivateDirSync(_parentDir);
        return _fs.withExclusiveLock(_lockPath,
            // Generous next to a real critical section (one keystore round-trip
            // plus a file write); a timeout therefore means a wedged live peer,
            // not normal contention.
            timeout: const Duration(seconds: 10),
            body: body);
      }
      _fs.verifyPrivateDirSync(_parentDir);
      return body();
    });
  }

  /// Loads and decrypts the whole store, applying the §7 failure matrix.
  /// Call only under [_serialized].
  ///
  /// [healOrphanedKey] is set by the mutating paths (write/delete): if a store
  /// key exists but the container is absent — the wedge left by a process
  /// crash between key creation and the first container write — they treat the
  /// store as empty and re-seal under the existing key, rather than throwing
  /// [ContainerMissing] forever. On the read paths it stays false so a lost
  /// container is reported loudly instead of silently looking empty.
  Future<Map<String, ContainerEntry>> _load(
      {bool healOrphanedKey = false}) async {
    final bytes = _fs.readCappedSync(path,
        maxBytes: maxContainerBytes, requirePrivate: true);
    final key = await _keySource.read();
    if (bytes == null) {
      if (key == null || healOrphanedKey) {
        return {}; // fresh install, or an orphaned key we're about to re-seal
      }
      throw ContainerMissing(path); // key orphaned by a lost container
    }
    if (key == null) {
      throw const StoreKeyMissing(); // ciphertext exists but key is gone
    }
    // WrongStoreKey / AuthenticationFailed / ContainerCorrupt from here.
    return _container.open(bytes, key);
  }

  /// Encrypts and atomically writes [entries], creating the store key on first
  /// write. If the write fails right after a *fresh* key was created, the key
  /// is rolled back so the store returns to a clean uninitialized state rather
  /// than a key-without-container orphan. Call only under an exclusive
  /// [_serialized].
  Future<void> _save(Map<String, ContainerEntry> entries) async {
    var key = await _keySource.read();
    final createdFreshKey = key == null;
    key ??= await _keySource.create();
    try {
      final sealed = await _container.seal(entries, key);
      // Reject before the atomic replace: the read side caps the container at
      // maxContainerBytes, so a larger file would make *every* subsequent read
      // fail closed. Checking here leaves the existing container untouched.
      if (sealed.length > maxContainerBytes) {
        throw StoreTooLarge(sealed.length, maxContainerBytes);
      }
      _fs.writeAtomicSync(path, sealed);
    } catch (_) {
      if (createdFreshKey) {
        try {
          await _keySource.delete();
        } catch (_) {
          // best effort — surface the original write error
        }
      }
      rethrow;
    }
  }

  @override
  Future<Uint8List?> read(String key) => _serialized(
      exclusive: false, body: () async => (await _load())[key]?.value);

  @override
  Future<bool> contains(String key) => _serialized(
      exclusive: false, body: () async => (await _load()).containsKey(key));

  @override
  Future<void> write(String key, Uint8List value, {String? label}) =>
      _serialized(
          exclusive: true,
          body: () async {
            final entries = await _load(healOrphanedKey: true);
            entries[key] =
                ContainerEntry(Uint8List.fromList(value), label: label);
            await _save(entries);
          });

  @override
  Future<void> delete(String key) => _serialized(
      exclusive: true,
      body: () async {
        final entries = await _load(healOrphanedKey: true);
        if (entries.remove(key) != null) {
          await _save(entries);
        }
      });

  @override
  Future<Map<String, Uint8List>> readAll() => _serialized(
      exclusive: false,
      body: () async {
        final entries = await _load();
        return {for (final e in entries.entries) e.key: e.value.value};
      });

  @override
  Future<BackendInfo> describe() async {
    final keyStatus = await _keySource.describe();
    final containerPresent = _fs.existsSync(path);
    return BackendInfo(
      scheme: StorageScheme.encryptedFile,
      available: keyStatus.available,
      locked: keyStatus.locked,
      capabilities: capabilities,
      // The level is whatever the key's home actually reports (measured, e.g.
      // Android inspects KeyInfo) — not a value the backend assumes.
      level: keyStatus.securityLevel,
      detail: 'container=${containerPresent ? 'present' : 'absent'} '
          'key=${keyStatus.present ? 'present' : 'absent'} '
          'via ${keyStatus.name}',
    );
  }
}

/// A minimal FIFO async mutex: bodies run one at a time, in call order.
class _TurnLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() body) {
    final prev = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    return prev.then((_) => body()).whenComplete(gate.complete);
  }
}
