/// A hardware-bound store-key source for headless servers, via `systemd-creds`
/// (see doc/design.md).
///
/// The 32-byte container store key is wrapped by `systemd-creds encrypt` and
/// only the *encrypted* blob is written to disk. On a machine with a TPM the
/// wrapping key never leaves the chip, so a stolen disk is useless without that
/// host's TPM — turning the headless deployment from a plaintext key on disk
/// (no real at-rest protection) into hardware-bound at rest.
///
/// This is the headless analogue of [SystemKeySource]: swap it in and the
/// container stays byte-for-byte the same. It shells out to `systemd-creds`
/// over the injectable [ProcessRunner] (so the command construction and error
/// mapping are unit-testable, and the real round-trip is integration-tested in
/// Docker with the `host` binding, which needs no TPM).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'ffi/posix_file.dart';
import 'ffi/process_runner.dart';
import 'key_source.dart';

/// How `systemd-creds` binds the wrapping key. The default requires a TPM —
/// that is the whole point of this source — and fails closed without one
/// rather than silently degrading (unlike systemd's own `auto`).
enum TpmKeyBinding {
  /// TPM2 **and** the host key (`/var/lib/systemd/credential.secret`) are both
  /// required to unwrap. Strongest: neither a stolen disk (no TPM) nor a bare
  /// TPM extraction (no host key) alone suffices. Needs a TPM.
  hostAndTpm2('host+tpm2'),

  /// TPM2 only. Hardware-bound; needs a TPM.
  tpm2('tpm2'),

  /// Host key only — **not hardware-bound**. The wrapping key lives on the same
  /// disk as the blob (`/var/lib/systemd/credential.secret`), so a full-disk
  /// theft recovers it; this is barely stronger than a plaintext key on disk.
  /// Provided for no-TPM environments and for testing the round-trip. Prefer a
  /// TPM binding for real protection.
  host('host');

  const TpmKeyBinding(this.value);

  /// The `--with-key=` value passed to `systemd-creds`.
  final String value;
}

/// Wraps the store key with `systemd-creds` (TPM2 / host key).
final class TpmKeySource implements KeySource {
  TpmKeySource({
    required this.path,
    this.binding = TpmKeyBinding.hostAndTpm2,
    this.name = 'secret_store',
    ProcessRunner runner = const SystemProcessRunner(),
    SecureFileSystem fs = const SecureFileSystem(),
    this.executable = 'systemd-creds',
    this.timeout = const Duration(seconds: 15),
  })  : _runner = runner,
        _fs = fs;

  /// Path to the on-disk *encrypted* credential blob (not the key).
  final String path;

  /// The key-binding mode; also the fail-closed guard (see [TpmKeyBinding]).
  final TpmKeyBinding binding;

  /// The credential name bound into the blob; `encrypt` and `decrypt` must
  /// agree, so it can't be swapped for another systemd credential.
  final String name;

  final String executable;
  final Duration timeout;
  final ProcessRunner _runner;
  final SecureFileSystem _fs;

  static const int _maxBlobBytes = 64 * 1024;

  List<String> _args(String verb) =>
      [verb, '--name=$name', '--with-key=${binding.value}', '-', '-'];

  Never _fail(ProcessRunResult r, String op) {
    // Never attach subprocess output — even systemd-creds' stderr can echo
    // context; and the plaintext transits its stdin/stdout.
    _scrub(r);
    if (r.launchFailed) {
      throw KeystoreUnreachable('$op: `$executable` not found');
    }
    if (r.timedOut) {
      throw KeystoreOperationFailed('$op: `$executable` timed out');
    }
    throw KeystoreOperationFailed('$op failed', status: r.exitCode);
  }

  void _scrub(ProcessRunResult r) {
    r.stdout.fillRange(0, r.stdout.length, 0);
    r.stderr.fillRange(0, r.stderr.length, 0);
  }

  @override
  Future<Uint8List?> read() async {
    final blob = _fs.readCappedSync(path, maxBytes: _maxBlobBytes);
    if (blob == null) return null;
    // The blob is systemd-creds' base64 text; feed it back on stdin verbatim.
    final r = await _runner.run(executable, _args('decrypt'),
        stdin: utf8.decode(blob), timeout: timeout);
    if (r.exitCode != 0 || r.launchFailed || r.timedOut) _fail(r, 'decrypt');
    try {
      // Decrypt returns the base64 we wrapped (the key never crosses the pipe
      // raw — arbitrary bytes wouldn't survive the String transport).
      final key = base64.decode(utf8.decode(r.stdout).trim());
      if (key.length != storeKeyLength) {
        throw KeystoreOperationFailed(
            'unwrapped key has wrong length (${key.length}, expected $storeKeyLength)');
      }
      return Uint8List.fromList(key);
    } on FormatException {
      throw const KeystoreOperationFailed(
          'unwrapped value was not valid base64');
    } finally {
      _scrub(r);
    }
  }

  @override
  Future<Uint8List> create() async {
    final key = generateStoreKey();
    final r = await _runner.run(executable, _args('encrypt'),
        stdin: base64.encode(key), timeout: timeout);
    if (r.exitCode != 0 || r.launchFailed || r.timedOut) _fail(r, 'encrypt');
    // stdout is the encrypted blob (base64 text); persist it 0600, atomically.
    _fs.writeAtomicSync(path, r.stdout);
    _scrub(r);
    return key;
  }

  @override
  Future<void> delete() async => _fs.deleteSync(path);

  @override
  Future<KeySourceStatus> describe() async {
    final present = _fs.existsSync(path);
    // `systemd-creds has-tpm2` exits 0 when a usable TPM2 is present.
    var tpmOk = false;
    var reachable = true;
    final probe = await _runner.run(executable, ['has-tpm2'], timeout: timeout);
    _scrub(probe);
    if (probe.launchFailed) {
      reachable = false;
    } else {
      tpmOk = probe.exitCode == 0;
    }
    final needsTpm = binding != TpmKeyBinding.host;
    return KeySourceStatus(
      name: 'tpm',
      present: present,
      available: reachable && (!needsTpm || tpmOk),
      detail: 'binding=${binding.value} '
          'systemd-creds=${reachable ? 'ok' : 'missing'} '
          'tpm2=${tpmOk ? 'present' : 'absent'}',
    );
  }
}
