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
    // `lookup` exits 1 both for a genuine miss AND for a locked collection that
    // fails without a prompter (headless, no GUI agent): with only `secret-tool`
    // we cannot tell them apart, so we report "not found". A present container
    // then surfaces as StoreKeyMissing, whose message is deliberately hedged
    // ("unlock and retry") rather than over-claiming a permanently lost key.
    // The desktop locked case is unaffected — a prompter blocks and the hard
    // timeout maps it to KeystoreLocked. (Tightening this needs the exit-code
    // matrix from the recorded TODO in probe().)
    if (r.exitCode == 1) {
      _scrub(r);
      return null; // not found (or a locked collection that failed fast)
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
  Future<bool> exists(String service, String account) async {
    // Attributes-only presence check. `secret-tool search` lists a matching
    // item's `attribute.account` line even when its collection is locked, and
    // prints the `secret = …` value only when unlocked — so existence is judged
    // from the parsed account lines, never by fetching and base64-decoding the
    // value the way `get`/`lookup` does. (lookup is additionally blind on a
    // locked collection, exiting 1 empty; search is not.) Both streams echo
    // secret material, so they are parsed at the byte level and scrubbed.
    final r = await _run(['search', '--all', ..._attrs(service, account)]);
    if (r.launchFailed || r.timedOut) _translate(r, 'exists');
    // Judge presence from the parsed attribute lines, never from the exit code
    // alone — the same discipline delete()'s confirm uses. `search` lists a
    // matching item's `attribute.account` even on a locked collection, so a
    // parsed hit is authoritative whatever the exit status; the exit code only
    // disambiguates a genuine no-match (exit 0, or exit 1 with empty output on
    // older secret-tool) from an unreadable/error result.
    final exit = r.exitCode;
    final bool present;
    final bool silent;
    try {
      present = {..._parseAccounts(r.stderr), ..._parseAccounts(r.stdout)}
          .contains(account);
      silent = r.stdout.isEmpty && r.stderr.isEmpty;
    } finally {
      _scrub(r);
    }
    if (present) return true;
    if (exit == 0) return false; // genuine no-match
    if (exit == 1 && silent) return false; // older secret-tool spelling of it
    // Nonzero (or exit 1 with diagnostics) and no parsed match: unconfirmable —
    // fail closed rather than report a possibly-present item as absent.
    throw KeystoreOperationFailed(
        'exists could not be confirmed (search exit $exit)',
        status: exit);
  }

  @override
  Future<void> set(String service, String account, Uint8List value,
      {String? label}) async {
    final r = await _run(
      [
        'store',
        '--label',
        label ?? 'keybay',
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
    final exit = r.exitCode;
    _scrub(r);
    if (exit == 0) return; // removed
    // `secret-tool clear`'s exit 1 is ambiguous: it means both "nothing
    // matched" (a no-op success — verified against real gnome-keyring) AND a
    // real failure (locked collection, D-Bus error). A security-sensitive
    // delete must not fail-open on that ambiguity, so confirm the item is
    // actually gone. The confirm must NOT use `lookup`: on a locked
    // collection lookup also exits 1 empty (the get() blindspot), which would
    // report a still-present item as deleted. `search` breaks the tie — it
    // still lists a matching item's attributes when its collection is locked,
    // printing the `secret =` line only when unlocked, and a no-match is
    // exit 0 with BOTH streams empty (all verified against real
    // gnome-keyring, including clear-then-search while locked). Presence is
    // therefore judged from the parsed attribute lines — never from the exit
    // code, which does not distinguish match from no-match. (The confirm is
    // as good as the provider's willingness to list locked items in a
    // search; gnome-keyring does. A provider that hides them entirely would
    // reopen the blindspot, beyond what secret-tool lets us see.)
    final s = await _run(['search', '--all', ..._attrs(service, account)]);
    if (s.launchFailed || s.timedOut) _translate(s, 'delete');
    final confirmExit = s.exitCode;
    final bool present;
    final bool secretVisible;
    final bool confirmSilent;
    try {
      // Our accounts pass validateIdentifier (ASCII), so a matched item's
      // account always parses; a hit on either stream means still present.
      present = {..._parseAccounts(s.stderr), ..._parseAccounts(s.stdout)}
          .contains(account);
      secretVisible = _hasSecretLine(s.stdout);
      confirmSilent = s.stdout.isEmpty && s.stderr.isEmpty;
    } finally {
      _scrub(s);
    }
    if (present) {
      // The item still matches: the clear failed. A hidden secret means the
      // collection is locked (the one state that lists an item without it).
      if (!secretVisible) {
        throw const KeystoreLocked(
            'delete could not remove the item: its collection is locked '
            '(headless session?) — unlock the keyring and retry');
      }
      throw KeystoreOperationFailed(
          'delete did not remove the item (clear exit $exit)',
          status: exit);
    }
    if (confirmExit == 0 && !present) {
      // Positive confirmation of absence: exit 0 means the query genuinely
      // ran against the service, and no matching item came back. Harmless
      // stderr noise (GLib warnings in a headless session) doesn't change
      // that — requiring silence here would turn every idempotent delete on
      // a noisy session into an error.
      return;
    }
    if (confirmExit == 1 && confirmSilent) {
      // Older secret-tool spelling of a clean no-match (current versions use
      // exit 0 empty). Exit 1 can also mean a connection failure, so this
      // form is only trusted when both streams are byte-empty.
      return;
    }
    // Anything else (unexpected exit, diagnostics without a parsed match):
    // removal is unconfirmable — fail closed rather than report success.
    throw KeystoreOperationFailed(
        'delete could not be confirmed (clear exit $exit, search exit '
        '$confirmExit)',
        status: confirmExit);
  }

  @override
  Future<Map<String, Uint8List>> getAll(String service) async {
    // `--` after the `--all` option, before the attribute pair (see _attrs).
    final r = await _run(['search', '--all', '--', 'service', service]);
    if (r.launchFailed || r.timedOut) _translate(r, 'getAll');
    // A no-match is exit 0 with empty output on current secret-tool (verified;
    // older versions spelled it exit 1, tolerated here) — either way the parse
    // below yields the empty map.
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
    // FROZEN keystore account constant (predates the keybay rename).
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

  /// Whether `secret-tool search` stdout in [out] contains a `secret =` line —
  /// printed exactly when a matched item's collection is unlocked, so its
  /// absence on a matched item means "locked". Byte-level for the same reason
  /// as [_parseAccounts]: the value on that line IS a secret, so the buffer is
  /// never decoded to a String. (The `secret-tool: ...` diagnostic lines on
  /// stderr never reach this, and a line must be exactly `secret` + `=` to
  /// match, so they couldn't false-positive anyway.)
  bool _hasSecretLine(Uint8List out) {
    final prefixBytes = 'secret'.codeUnits;
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
      if (p < e && out[p] == 0x3d /* '=' */) {
        return true;
      }
    }
    return false;
  }
}
