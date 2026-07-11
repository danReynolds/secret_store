/// Linux Secret Service via `secret-tool` (see doc/design.md).
///
/// libsecret's own CLI, so no D-Bus protocol of our own (a native client is a
/// recorded follow-up). The secret always crosses on **stdin** (never argv —
/// argv is `ps`-visible), base64-encoded so binary/newlines survive the pipe.
/// Every call has a **hard timeout**: `secret-tool` has no no-prompt flag and
/// a locked collection spawns a GUI prompter, which over SSH would hang
/// forever; on timeout we kill it and surface a typed [KeystoreLocked].
///
/// Base64 uses `dart:convert` (the input side accepts one transient `String` of
/// the encoded secret — a copy the GC can't zero, but neither can it zero the
/// secret's own `Uint8List`, so a hand-rolled bytes-only codec bought little
/// and was cut). Subprocess **output** is kept as bytes: it can echo secret
/// material (`lookup` prints the stored value; `search` echoes stored items;
/// a failed `store` echoes its stdin), so it is parsed at the byte level,
/// scrubbed (zeroed) after use, and never attached to a surfaced error.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import 'keystore_api.dart';
import 'process_runner.dart';

/// Secret Service backing via `secret-tool`.
final class SecretToolApi implements KeystoreApi {
  SecretToolApi({
    ProcessRunner runner = const SystemProcessRunner(),
    this.executable = 'secret-tool',
    this.timeout = const Duration(seconds: 15),
  }) : _runner = runner;

  final ProcessRunner _runner;

  /// `secret-tool` resolved via PATH by default; override to pin an absolute
  /// path (a same-user PATH hijack is outside the threat model, but the knob
  /// costs nothing).
  final String executable;

  /// Hard per-call timeout; a locked collection would otherwise hang on a GUI
  /// prompt.
  final Duration timeout;

  // A leading `--` terminates `secret-tool`'s option parsing, so an attribute
  // value that begins with `-` (a `service` derived from an appId like
  // `--unlock`) is treated as data, never as a command-line option. Every
  // attribute list is prefixed with it.
  List<String> _attrs(String service, String account) =>
      ['--', 'service', service, 'account', account];

  Future<ProcessRunResult> _run(List<String> args, {String? stdin}) =>
      _runner.run(executable, args, stdin: stdin, timeout: timeout);

  /// Zeroes captured subprocess output. Output can echo secret material, so
  /// every path scrubs the buffers once it has extracted what it needs.
  void _scrub(ProcessRunResult r) {
    r.stdout.fillRange(0, r.stdout.length, 0);
    r.stderr.fillRange(0, r.stderr.length, 0);
  }

  Never _translate(ProcessRunResult r, String op) {
    _scrub(r);
    if (r.launchFailed) {
      throw KeystoreUnreachable('$op: `$executable` not found');
    }
    if (r.timedOut) {
      throw KeystoreLocked('$op: `$executable` timed out (locked collection?)');
    }
    // Never include stdout/stderr — a failed store echoes the base64 value.
    throw KeystoreOperationFailed('$op failed', status: r.exitCode);
  }

  @override
  Future<Uint8List?> get(String service, String account) async {
    final r = await _run(['lookup', ..._attrs(service, account)]);
    if (r.launchFailed || r.timedOut) _translate(r, 'get');
    if (r.exitCode == 1) {
      _scrub(r);
      return null; // not found
    }
    if (r.exitCode != 0) _translate(r, 'get');
    try {
      final text = utf8.decode(r.stdout, allowMalformed: true).trim();
      return Uint8List.fromList(base64.decode(text));
    } on FormatException {
      throw const KeystoreOperationFailed('stored value was not valid base64');
    } finally {
      _scrub(r);
    }
  }

  @override
  Future<void> set(String service, String account, Uint8List value,
      {String? label}) async {
    final r = await _run(
      [
        'store',
        '--label',
        label ?? 'secret_store',
        ..._attrs(service, account),
      ],
      stdin: base64.encode(value),
    );
    if (r.exitCode != 0) _translate(r, 'set');
    _scrub(r);
  }

  @override
  Future<void> delete(String service, String account) async {
    final r = await _run(['clear', ..._attrs(service, account)]);
    if (r.launchFailed || r.timedOut) _translate(r, 'delete');
    // Idempotent: `secret-tool clear` exits 1 when nothing matched (verified
    // against real gnome-keyring — an earlier assumption that it exits 0 was
    // wrong and broke delete-of-absent). A no-match is a no-op success, like
    // `get`'s exit-1 → null. Only other nonzero codes are real failures.
    if (r.exitCode != 0 && r.exitCode != 1) _translate(r, 'delete');
    _scrub(r);
  }

  @override
  Future<Map<String, Uint8List>> getAll(String service) async {
    // `--` after the `--all` option, before the attribute pair (see _attrs).
    final r = await _run(['search', '--all', '--', 'service', service]);
    if (r.launchFailed || r.timedOut) _translate(r, 'getAll');
    // `search` exits 1 when nothing matches.
    if (r.exitCode == 1) {
      _scrub(r);
      return {};
    }
    if (r.exitCode != 0) _translate(r, 'getAll');
    // `secret-tool search` prints the item bodies (INCLUDING `secret = …`) to
    // stdout and the `attribute.account = …` lines to stderr (verified against
    // real gnome-keyring). Parse both streams for account attributes — stderr
    // is where they actually are; scanning stdout too is harmless (its
    // `secret =` lines don't match the attribute prefix) and robust to version
    // differences. Both streams are scrubbed after.
    final Set<String> accounts;
    try {
      accounts = {..._parseAccounts(r.stderr), ..._parseAccounts(r.stdout)};
    } finally {
      _scrub(r);
    }
    final result = <String, Uint8List>{};
    for (final account in accounts) {
      final v = await get(service, account);
      if (v != null) result[account] = v;
    }
    return result;
  }

  @override
  Future<KeystoreProbe> probe(String service) async {
    final r =
        await _run(['lookup', ..._attrs(service, '__secret_store_probe__')]);
    _scrub(r); // output is irrelevant to the probe and could be a real value
    if (r.launchFailed) {
      return KeystoreProbe(
          available: false, locked: false, detail: '`$executable` not found');
    }
    if (r.timedOut) {
      return const KeystoreProbe(
          available: true, locked: true, detail: 'timed out (locked?)');
    }
    // exit 0 (found, unlikely) or 1 (not found) both mean reachable+unlocked.
    // TODO(behavior-matrix): a locked headless collection that fails *fast*
    // (no prompter registered) exits nonzero and lands here too — building the
    // dbus-run-session integration harness and mapping those exits precisely
    // is a recorded follow-up.
    return const KeystoreProbe(available: true, locked: false);
  }

  /// Extracts `attribute.account = NAME` values from `secret-tool search`
  /// output **at the byte level**: search output also echoes each item's
  /// secret (`secret = ...`), so the buffer must never be decoded to a String
  /// wholesale. Only the account attribute values (identifiers, non-secret)
  /// are decoded; lines that aren't valid UTF-8 are skipped.
  List<String> _parseAccounts(Uint8List out) {
    const prefix = 'attribute.account';
    final prefixBytes = prefix.codeUnits;
    final accounts = <String>[];
    var lineStart = 0;
    for (var i = 0; i <= out.length; i++) {
      if (i != out.length && out[i] != 0x0a) {
        continue;
      }
      var s = lineStart;
      var e = i;
      lineStart = i + 1;
      if (e > s && out[e - 1] == 0x0d) e--;
      while (s < e && (out[s] == 0x20 || out[s] == 0x09)) {
        s++;
      }
      if (e - s <= prefixBytes.length) {
        continue;
      }
      var matches = true;
      for (var j = 0; j < prefixBytes.length; j++) {
        if (out[s + j] != prefixBytes[j]) {
          matches = false;
          break;
        }
      }
      if (!matches) {
        continue;
      }
      var p = s + prefixBytes.length;
      while (p < e && (out[p] == 0x20 || out[p] == 0x09)) {
        p++;
      }
      if (p >= e || out[p] != 0x3d /* '=' */) {
        continue;
      }
      p++;
      while (p < e && (out[p] == 0x20 || out[p] == 0x09)) {
        p++;
      }
      var q = e;
      while (q > p && (out[q - 1] == 0x20 || out[q - 1] == 0x09)) {
        q--;
      }
      if (q <= p) {
        continue;
      }
      try {
        accounts.add(utf8.decode(out.sublist(p, q), allowMalformed: false));
      } on FormatException {
        // An item written by another app with a non-UTF-8 account: skip it.
      }
    }
    return accounts;
  }
}
