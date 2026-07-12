/// The authenticated encrypted container (see doc/design.md).
///
/// On-disk layout (version 2):
/// ```
/// magic "DSS1" (4) | version u8 | cipher u8 | keyCommit(32)
///   | nonce(24) | ciphertext | tag(16)
/// ```
/// Version 1 was the pre-release format without the keyCommit field; its
/// layout is incompatible, so it is rejected by version byte as
/// [ContainerCorrupt] ("unsupported version") rather than misread — the
/// version byte exists precisely so a layout change never surfaces as a
/// misleading [WrongStoreKey].
/// - AEAD key  = HKDF-SHA256(storeKey, salt: contextSalt,
///                           info: "secret_store:v1:container" ‖ cipherId)
/// - keyCommit = HKDF-SHA256(storeKey, salt: contextSalt,
///                           info: "secret_store:v1:commit" ‖ cipherId)
/// - AAD       = magic ‖ version ‖ cipher ‖ keyCommit ‖ contextSalt
/// - cipher    = XChaCha20-Poly1305
///
/// **Key commitment.** XChaCha20-Poly1305 is not key-committing on its own
/// (one ciphertext can be crafted to open under two keys). [keyCommit] pins
/// the (storeKey, contextSalt) pair and is checked in constant time *before*
/// decryption, so "wrong key/context" ([WrongStoreKey]) is distinct from
/// "tampered" ([AuthenticationFailed]), and multi-key ciphertext games fail
/// closed. The distinction is one-directional, though: a flipped bit in the
/// stored commit field *itself* also fails the commitment check and reports
/// [WrongStoreKey] — by construction indistinguishable from a genuinely
/// different key — while tamper anywhere else still reports
/// [AuthenticationFailed]. The commit value is a PRF output under a uniformly
/// random 256-bit key; it reveals nothing about the key and cannot be
/// brute-forced. It *is* deterministic for a given (storeKey, contextSalt),
/// so two containers (or backups of one) sealed under the same key show the
/// same commit value: an observer can correlate them and see when the key
/// rotates — it discloses key *equality*, never key material. Its cost is one
/// HKDF + a 32-byte header field; its primary *delivered* value is that clean
/// error distinction (the attack it closes sits at the edge of the threat
/// model) — cheap defense-in-depth, kept on that basis.
///
/// The raw store key is never used directly as the AEAD key — HKDF gives
/// domain separation so the same keystore key could later serve other purposes
/// without cross-protocol reuse.
///
/// (There is deliberately **no** rollback/generation field: a counter bound in
/// the AAD is only tamper-evident, not anti-rollback — an attacker who restores
/// a whole older container restores its counter too — so it bought no security
/// on its own. Real rollback resistance needs a keystore-anchored monotonic
/// counter; if that lands it is a versioned format change (header-version
/// bump), not an inert field carried speculatively now.)
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../errors.dart';
import 'tlv.dart';

const List<int> _magic = [0x44, 0x53, 0x53, 0x31]; // "DSS1"
// 2 = keyCommit header (current). 1 = the commitment-less pre-release layout,
// rejected. (The "v1" inside the HKDF info strings below is an independent
// protocol domain label, not this header byte — changing it would re-key
// every store, so it stays fixed across compatible header revisions. The
// same goes for the strings' `secret_store:` prefix: a frozen wire-format
// constant predating the package's rename to `keyway`, never rebranded —
// changing it would be a container-format version bump.)
const int _version = 2;
const int _cipherXChaCha20Poly1305 = 1;
const int _commitLength = 32;
const int _nonceLength = 24;
const int _tagLength = 16;
// magic(4) + version(1) + cipher(1) + commit(32)
const int _headerLength = 6 + _commitLength;
const int _commitOffset = 6;
const int _nonceOffset = _headerLength;

/// Seals/opens the whole-store TLV payload under a 32-byte store key.
///
/// [contextSalt] is an internal seam: no public path supplies a salt — the
/// resolver always passes an empty one today. A non-empty salt binds the
/// container to a caller identity (it is the HKDF salt for both derived
/// values and part of the AEAD AAD), so a container moved between contexts
/// fails the key-commitment check even under a hypothetically shared key.
final class Container {
  Container({required List<int> contextSalt})
      : _contextSalt = Uint8List.fromList(contextSalt);

  final Uint8List _contextSalt;
  // The concrete pure-Dart implementations, NOT the `Xchacha20.poly1305Aead()`
  // / `Hkdf(...)` factories: those resolve through the global mutable
  // `Cryptography.instance` service locator, which a host application (e.g.
  // `FlutterCryptography.enable()`) can swap at runtime — substituting an
  // implementation our vector firewall never ran against. Constructing the
  // Dart classes directly pins the exact audited code.
  final _aead = DartXchacha20.poly1305Aead();
  final Random _rng = Random.secure();

  static final _hkdf =
      DartHkdf(hmac: const DartHmac(DartSha256()), outputLength: 32);
  static final _aeadInfo = Uint8List.fromList([
    ...utf8.encode('secret_store:v1:container'),
    _cipherXChaCha20Poly1305,
  ]);
  static final _commitInfo = Uint8List.fromList([
    ...utf8.encode('secret_store:v1:commit'),
    _cipherXChaCha20Poly1305,
  ]);

  Future<SecretKey> _deriveAeadKey(List<int> storeKey) async {
    return _hkdf.deriveKey(
      secretKey: SecretKey(storeKey),
      nonce: _contextSalt, // HKDF salt (verified against RFC 5869 in tests)
      info: _aeadInfo,
    );
  }

  Future<Uint8List> _deriveCommit(List<int> storeKey) async {
    final k = await _hkdf.deriveKey(
      secretKey: SecretKey(storeKey),
      nonce: _contextSalt,
      info: _commitInfo,
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  Uint8List _aad(Uint8List commit) => Uint8List.fromList([
        ..._magic,
        _version,
        _cipherXChaCha20Poly1305,
        ...commit,
        ..._contextSalt,
      ]);

  /// Encrypts [entries] into container bytes ready to write to disk.
  Future<Uint8List> seal(
    Map<String, ContainerEntry> entries,
    List<int> storeKey,
  ) async {
    final plaintext = encodeTlv(entries);
    final key = await _deriveAeadKey(storeKey);
    final commit = await _deriveCommit(storeKey);
    final nonce = Uint8List(_nonceLength);
    for (var i = 0; i < _nonceLength; i++) {
      nonce[i] = _rng.nextInt(256);
    }
    final SecretBox box;
    try {
      box = await _aead.encrypt(
        plaintext,
        secretKey: key,
        nonce: nonce,
        aad: _aad(commit),
      );
    } finally {
      // Best-effort scrub of the concatenated-secrets buffer. Dart-heap memory
      // cannot be reliably zeroed (the GC may already have copied it), so this
      // only narrows the window — the package's load-bearing scrub guarantee is
      // for native buffers. Free, so worth doing.
      plaintext.fillRange(0, plaintext.length, 0);
    }
    // magic|version|cipher|commit | nonce | ciphertext | tag
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(_version)
      ..addByte(_cipherXChaCha20Poly1305)
      ..add(commit)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Decrypts container [bytes]. Throws [ContainerCorrupt] on a structurally
  /// invalid envelope, [WrongStoreKey] when the key-commitment check fails
  /// (wrong key or wrong context), and [AuthenticationFailed] on tamper /
  /// corruption under a matching key. Never returns partial or empty data on
  /// failure.
  Future<Map<String, ContainerEntry>> open(
    Uint8List bytes,
    List<int> storeKey,
  ) async {
    if (bytes.length < _headerLength + _nonceLength + _tagLength) {
      throw const ContainerCorrupt('too short to be a container');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        throw const ContainerCorrupt('bad magic');
      }
    }
    final version = bytes[4];
    final cipher = bytes[5];
    if (version != _version) {
      throw ContainerCorrupt('unsupported version $version');
    }
    if (cipher != _cipherXChaCha20Poly1305) {
      throw ContainerCorrupt('unsupported cipher $cipher');
    }
    final storedCommit = Uint8List.sublistView(
        bytes, _commitOffset, _commitOffset + _commitLength);

    // Key commitment, checked before any decryption is attempted.
    final expectedCommit = await _deriveCommit(storeKey);
    if (!_constantTimeEquals(expectedCommit, storedCommit)) {
      throw const WrongStoreKey();
    }

    final nonce =
        Uint8List.sublistView(bytes, _nonceOffset, _nonceOffset + _nonceLength);
    final cipherStart = _nonceOffset + _nonceLength;
    final tagStart = bytes.length - _tagLength;
    final cipherText = Uint8List.sublistView(bytes, cipherStart, tagStart);
    final tag = Uint8List.sublistView(bytes, tagStart);

    final key = await _deriveAeadKey(storeKey);
    final List<int> plaintext;
    try {
      plaintext = await _aead.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
        aad: _aad(storedCommit),
      );
    } on SecretBoxAuthenticationError {
      throw const AuthenticationFailed();
    }
    // decodeTlv copies every value into its own buffer, so the concatenated
    // plaintext can be scrubbed once decoding is done. Best-effort, as in
    // seal(): a Dart-heap scrub only narrows the window.
    final buf = Uint8List.fromList(plaintext);
    if (plaintext is Uint8List) {
      plaintext.fillRange(0, plaintext.length, 0);
    }
    try {
      return decodeTlv(buf);
    } finally {
      buf.fillRange(0, buf.length, 0);
    }
  }
}

/// Constant-time byte comparison (no early exit), for the key-commitment
/// check. As constant-time as Dart gets; the value compared is a public PRF
/// output, so this is defense in depth rather than a load-bearing property.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
