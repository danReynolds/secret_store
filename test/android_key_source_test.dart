@Tags(['unit'])
library;

import 'dart:typed_data';

import 'package:keybay/src/android_keystore_key_source.dart';
import 'package:keybay/src/app_paths.dart';
import 'package:keybay/src/errors.dart';
import 'package:test/test.dart';

// The JNI/Keystore choreography itself is covered by the emulator tier
// (example_flutter/); these are the pure parts — the wrapped-blob codec and
// the Context-free path derivation.
void main() {
  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  group('wrapped-key blob codec', () {
    final iv = bytes(List.generate(12, (i) => i + 1));
    final ct = bytes(List.generate(48, (i) => 255 - i)); // 32 key + 16 tag

    test('round-trips, preserving iv/ct', () {
      final encoded =
          encodeWrappedKeyBlob(WrappedKeyBlob(iv: iv, ciphertext: ct));
      final decoded = decodeWrappedKeyBlob(encoded);
      expect(decoded.iv, iv);
      expect(decoded.ciphertext, ct);
    });

    test('the reserved byte is ignored, not rejected', () {
      // A non-zero reserved byte (formerly the StrongBox flag) must still
      // decode — the field carries no meaning and older blobs may have set it.
      final full = encodeWrappedKeyBlob(WrappedKeyBlob(iv: iv, ciphertext: ct));
      final withReserved = Uint8List.fromList(full)..[4] = 0x01;
      final decoded = decodeWrappedKeyBlob(withReserved);
      expect(decoded.iv, iv);
      expect(decoded.ciphertext, ct);
    });

    test('every truncation throws KeyInvalidated (never crashes)', () {
      final full = encodeWrappedKeyBlob(WrappedKeyBlob(iv: iv, ciphertext: ct));
      for (var cut = 0; cut < full.length; cut++) {
        expect(() => decodeWrappedKeyBlob(Uint8List.sublistView(full, 0, cut)),
            throwsA(isA<KeyInvalidated>()),
            reason: 'prefix of length $cut');
      }
    });

    test('trailing garbage and bad magic throw KeyInvalidated', () {
      final full = encodeWrappedKeyBlob(WrappedKeyBlob(iv: iv, ciphertext: ct));
      expect(() => decodeWrappedKeyBlob(Uint8List.fromList([...full, 0])),
          throwsA(isA<KeyInvalidated>()),
          reason: 'trailing byte');
      expect(() => decodeWrappedKeyBlob(Uint8List.fromList(full)..[0] ^= 0xFF),
          throwsA(isA<KeyInvalidated>()),
          reason: 'bad magic');
    });

    test('encode rejects out-of-range lengths', () {
      expect(
          () => encodeWrappedKeyBlob(
              WrappedKeyBlob(iv: Uint8List(0), ciphertext: ct)),
          throwsArgumentError);
      expect(
          () => encodeWrappedKeyBlob(
              WrappedKeyBlob(iv: iv, ciphertext: Uint8List(0))),
          throwsArgumentError);
      expect(
          () => encodeWrappedKeyBlob(
              WrappedKeyBlob(iv: Uint8List(64), ciphertext: ct)),
          throwsArgumentError);
    });
  });

  group('Android path derivation (Context-free, strict)', () {
    test('derives dataDir from the framework tmpdir (cache) layout', () {
      expect(androidDataDirFromTmpdir('/data/user/0/com.example.app/cache'),
          '/data/user/0/com.example.app');
      expect(androidDataDirFromTmpdir('/data/user/0/com.example.app/cache/'),
          '/data/user/0/com.example.app');
      expect(
          androidContainerPathFor('com.example.app',
              tmpdir: '/data/user/0/com.example.app/cache'),
          '/data/user/0/com.example.app/files/com.example.app/secrets.enc');
    });

    test('anything surprising fails closed instead of guessing', () {
      for (final bad in [
        '', // unset
        'cache', // relative
        '/cache', // empty dataDir
        '/tmp', // not a cache dir
        '/data/user/0/app/Cache', // wrong case
        '/data/user/0/app/cache/extra', // not the leaf
      ]) {
        expect(() => androidDataDirFromTmpdir(bad),
            throwsA(isA<KeystoreUnreachable>()),
            reason: '"$bad"');
      }
    });
  });
}
