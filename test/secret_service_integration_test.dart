@Tags(['integration'])
@TestOn('linux')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:keyway/keyway.dart' show SecretStorage;
import 'package:keyway/src/backend.dart';
import 'package:keyway/src/ffi/secret_service.dart';
import 'package:test/test.dart';

/// Exercises the REAL Linux Secret Service via `secret-tool` against a live
/// gnome-keyring. Opt-in and Linux-only; the scripted [ProcessRunner] test
/// (`secret_service_test.dart`) covers command construction and error mapping
/// without a keyring, while this proves the real round-trip.
///
/// CI runs it under `dbus-run-session` with a fresh, unlocked keyring
/// (see .github/workflows/ci.yml). Locally on Linux:
///   dbus-run-session -- bash -c '
///     eval "$(printf pw | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
///     KEYWAY_INTEGRATION=1 dart test test/secret_service_integration_test.dart'
void main() {
  final envEnabled = Platform.environment['KEYWAY_INTEGRATION'] == '1';
  final skip =
      envEnabled ? false : 'set KEYWAY_INTEGRATION=1 (Linux, unlocked keyring)';

  final api = SecretToolApi();
  const service = 'ca.danreynolds.keyway.itest';

  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  Future<void> cleanup() async {
    for (final acct in ['a', 'b', 'k']) {
      await api.delete(service, acct);
    }
  }

  setUp(cleanup);
  tearDown(cleanup);

  test('probe reports available and unlocked', () async {
    final p = await api.probe(service);
    expect(p.available, isTrue);
    expect(p.locked, isFalse);
  }, skip: skip);

  test('set / get / update / delete round-trips real bytes', () async {
    expect(await api.get(service, 'k'), isNull);

    await api.set(service, 'k', bytes([1, 2, 3, 0, 255]), label: 'itest key');
    expect(await api.get(service, 'k'), [1, 2, 3, 0, 255]);

    // upsert (store over an existing account replaces the value)
    await api.set(service, 'k', bytes([9, 9]));
    expect(await api.get(service, 'k'), [9, 9]);

    await api.delete(service, 'k');
    expect(await api.get(service, 'k'), isNull);
    await api.delete(service, 'k'); // idempotent
  }, skip: skip);

  test('binary values with NULs and every byte survive the base64 transport',
      () async {
    final v = bytes(List.generate(256, (i) => i)); // 0x00..0xFF, incl. newline
    await api.set(service, 'k', v);
    expect(await api.get(service, 'k'), v);
  }, skip: skip);

  test('enumerates all accounts under a service', () async {
    await api.set(service, 'a', bytes([1]));
    await api.set(service, 'b', bytes([2, 2]));
    final all = await api.getAll(service);
    expect(all.keys.toSet(), containsAll(<String>{'a', 'b'}));
    expect(all['a'], [1]);
    expect(all['b'], [2, 2]);
  }, skip: skip);

  test('empty getAll on an unused service', () async {
    expect(await api.getAll('$service.empty'), isEmpty);
  }, skip: skip);

  group('resolver end-to-end (SecretStorage(appId:) on real Linux)', () {
    // The resolver must compose the encrypted file under
    // ${XDG_DATA_HOME:-~/.local/share}/<appId>/ with its key in the real
    // Secret Service, level loginBound.
    const appId = 'ca.danreynolds.secret-store.itest-resolver';

    Directory dataDir() {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final base = (xdg != null && xdg.startsWith('/'))
          ? xdg
          : '${Platform.environment['HOME']}/.local/share';
      return Directory('$base/$appId');
    }

    Future<void> cleanupResolved() async {
      final d = dataDir();
      if (d.existsSync()) d.deleteSync(recursive: true);
      await api.delete(appId, 'store-key'); // idempotent
    }

    setUp(cleanupResolved);
    tearDown(cleanupResolved);

    test('resolves to encrypted-file + Secret Service key and round-trips',
        () async {
      final store = SecretStorage(appId: appId);

      final info = await store.backend.describe();
      expect(info.scheme, StorageScheme.encryptedFile);
      expect(info.level, SecurityLevel.loginBound);

      await store.writeString('token', 's3cr3t');
      expect(await store.readString('token'), 's3cr3t');

      // Container at the derived path; raw file is ciphertext.
      final file = File('${dataDir().path}/secrets.enc');
      expect(file.existsSync(), isTrue);
      expect(String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('s3cr3t')));

      // The wrapping key is a real Secret Service item under the appId.
      expect(await api.get(appId, 'store-key'), isNotNull);

      // A second store instance reads the same data.
      expect(await SecretStorage(appId: appId).readString('token'), 's3cr3t');

      await store.delete('token');
      expect(await store.readString('token'), isNull);
    }, skip: skip);
  });
}
