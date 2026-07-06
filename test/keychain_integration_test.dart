@Tags(['integration'])
@TestOn('mac-os')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:secret_store/src/ffi/keychain.dart';
import 'package:test/test.dart';

/// Exercises the REAL macOS login Keychain. Opt-in — these create and delete
/// items under a throwaway service and may surface an auth dialog on some
/// machines. Run with:
///   SECRET_STORE_INTEGRATION=1 dart test -t integration
void main() {
  // Runtime gate (not a compile-time define): export SECRET_STORE_INTEGRATION=1.
  final envEnabled = Platform.environment['SECRET_STORE_INTEGRATION'] == '1';
  final skip = envEnabled ? false : 'set SECRET_STORE_INTEGRATION=1';

  final api = MacKeychainApi();
  const service = 'ca.danreynolds.secret_store.itest';

  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  setUp(() {
    // clean slate
    for (final acct in ['a', 'b', 'k']) {
      api.delete(service, acct);
    }
  });
  tearDown(() {
    for (final acct in ['a', 'b', 'k']) {
      api.delete(service, acct);
    }
  });

  test('add / get / update / delete round-trips real bytes', () {
    expect(api.get(service, 'k'), isNull);

    api.set(service, 'k', bytes([1, 2, 3, 0, 255]), label: 'itest key');
    expect(api.get(service, 'k'), [1, 2, 3, 0, 255]);

    // upsert (duplicate -> update)
    api.set(service, 'k', bytes([9, 9]));
    expect(api.get(service, 'k'), [9, 9]);

    api.delete(service, 'k');
    expect(api.get(service, 'k'), isNull);
    api.delete(service, 'k'); // idempotent
  }, skip: skip);

  test('enumerates all accounts under a service', () {
    api.set(service, 'a', bytes([1]));
    api.set(service, 'b', bytes([2, 2]));
    final all = api.getAll(service);
    expect(all.keys.toSet(), containsAll(<String>{'a', 'b'}));
    expect(all['a'], [1]);
    expect(all['b'], [2, 2]);
  }, skip: skip);

  test('binary values with embedded NULs survive the CFData round-trip', () {
    final v = bytes(List.generate(64, (i) => (i * 7) % 256));
    api.set(service, 'k', v);
    expect(api.get(service, 'k'), v);
  }, skip: skip);

  test('probe reports available/unlocked on a normal session', () {
    final p = api.probe(service);
    expect(p.available, isTrue);
  }, skip: skip);
}
