@Tags(['integration'])
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:secret_store/src/ffi/secret_service.dart';
import 'package:test/test.dart';

/// Pins the documented Linux limitation that a **locked** Secret Service
/// collection is indistinguishable from "not found" via `secret-tool lookup`
/// (see [SecretToolApi.get] and the `probe()` TODO): with no prompter, `lookup`
/// exits 1 with empty stdout/stderr for a locked item, byte-for-byte identical
/// to a genuine miss. So the library reports `null` (never crashes) and cannot
/// surface `KeystoreLocked` from `lookup` alone — the honest `StoreKeyMissing`
/// message accounts for exactly this ambiguity.
///
/// This test **locks the login collection** and cannot unlock it again without a
/// prompter, so it must run in its **own** `dbus-run-session` — CI gives it a
/// dedicated step (see .github/workflows/ci.yml) so it can't strand the
/// unlocked integration tier. Locally on Linux:
///   dbus-run-session -- bash -c '
///     eval "$(printf pw | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
///     SECRET_STORE_INTEGRATION=1 dart test test/secret_service_locked_integration_test.dart'
void main() {
  final envEnabled = Platform.environment['SECRET_STORE_INTEGRATION'] == '1';
  final skip = envEnabled
      ? false
      : 'set SECRET_STORE_INTEGRATION=1 (Linux, own unlocked dbus session)';

  test(
    'a locked collection presents a stored item as not-found (get() returns '
    'null, never crashes)',
    () async {
      final api = SecretToolApi();
      const service = 'ca.danreynolds.secret_store.locktest';
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
    },
    skip: skip,
    // Locking can prompt-and-fail slowly on some builds; keep well clear of the
    // per-call 15 s secret-tool timeout without hanging CI.
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
