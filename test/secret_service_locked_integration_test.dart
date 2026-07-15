@Tags(['integration'])
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:keybay/keybay.dart' show KeystoreLocked;
import 'package:keybay/src/ffi/secret_service.dart';
import 'package:test/test.dart';

/// Pins the documented Linux limitation that a **locked** Secret Service
/// collection is indistinguishable from "not found" via `secret-tool lookup`
/// (see [SecretToolApi.get] and the `probe()` TODO): with no prompter, `lookup`
/// exits 1 with empty stdout/stderr for a locked item, byte-for-byte identical
/// to a genuine miss. So the library reports `null` (never crashes) and cannot
/// surface `KeystoreLocked` from `lookup` alone — the honest `StoreKeyMissing`
/// message accounts for exactly this ambiguity.
///
/// `delete()`, by contrast, must NOT inherit that blindspot: its
/// clear-then-confirm path confirms via `search` (which lists a matching
/// item's attributes even in a locked collection) and fails closed with
/// [KeystoreLocked] while the item persists — pinned below against the real
/// keyring.
///
/// This test **locks the login collection** and cannot unlock it again without a
/// prompter, so it must run in its **own** `dbus-run-session` — CI gives it a
/// dedicated step (see .github/workflows/ci.yml) so it can't strand the
/// unlocked integration tier. It therefore requires a second opt-in beyond
/// KEYBAY_INTEGRATION: on a real desktop session `-t integration` would
/// otherwise lock the developer's actual login keyring (unlock prompt, and a
/// stranded test item). CI and tool/test_linux.sh set both. Locally on Linux:
///   dbus-run-session -- bash -c '
///     eval "$(printf pw | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
///     KEYBAY_INTEGRATION=1 KEYBAY_LOCKED_TEST=1 \
///       dart test test/secret_service_locked_integration_test.dart'
void main() {
  final envEnabled = Platform.environment['KEYBAY_INTEGRATION'] == '1' &&
      Platform.environment['KEYBAY_LOCKED_TEST'] == '1';
  final skip = envEnabled
      ? false
      : 'set KEYBAY_INTEGRATION=1 and KEYBAY_LOCKED_TEST=1 — this '
          'test LOCKS the session\'s login collection, so it is safe only in a '
          'throwaway dbus-run-session (CI / tool/test_linux.sh), never a real '
          'desktop session';

  test(
    'a locked collection presents a stored item as not-found (get() returns '
    'null, never crashes)',
    () async {
      final api = SecretToolApi();
      const service = 'ca.danreynolds.keybay.locktest';
      final value = Uint8List.fromList(utf8.encode('locked-secret'));

      await api.set(service, 'k', value, label: 'lock test');
      expect(await api.get(service, 'k'), isNotNull,
          reason: 'sanity: the item is readable while the keyring is unlocked');

      // Lock the default (login) collection via the Secret Service D-Bus API.
      final lock = await Process.run('dbus-send', const [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.secrets',
        '/org/freedesktop/secrets',
        'org.freedesktop.Secret.Service.Lock',
        'array:objpath:/org/freedesktop/secrets/collection/login',
      ]);
      expect(lock.exitCode, 0,
          reason: 'could not lock the login collection: ${lock.stderr}');

      // With no prompter, `secret-tool lookup` on the now-locked item exits 1
      // empty — indistinguishable from a miss — so get() reports null. The
      // property under test is "degrades to null, does not throw/hang".
      expect(await api.get(service, 'k'), isNull,
          reason: 'a locked collection must present as not-found, not crash');

      // delete() must fail CLOSED here: `clear` exits 1 and leaves the item in
      // the locked collection, and the confirm-search still sees it (without
      // its secret) — so the library must throw KeystoreLocked, never report a
      // deletion that did not happen.
      await expectLater(
          api.delete(service, 'k'), throwsA(isA<KeystoreLocked>()),
          reason: 'delete() must not report success while the locked '
              'collection still holds the item');
    },
    skip: skip,
    // Locking can prompt-and-fail slowly on some builds; keep well clear of the
    // per-call 15 s secret-tool timeout without hanging CI.
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
