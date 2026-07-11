/// Android Keystore [KeySource]: the container's 32-byte store key is wrapped
/// by an AES-256-GCM key that lives **inside** AndroidKeyStore (TEE, or
/// StrongBox where present) and never leaves hardware. Only the wrapped blob
/// touches disk, beside the container. See doc/implementation-plan.md Phase 3.
///
/// Reliability posture (the ecosystem lessons, design.md §9):
/// - KEK is generated with `setUserAuthenticationRequired(false)` — the
///   best-case reliability profile (no biometric-enrollment invalidation).
/// - **StrongBox try-then-fallback**: attempt `setIsStrongBoxBacked(true)`,
///   fall back to TEE on `StrongBoxUnavailableException` (most devices).
/// - **Write-time self-test**: after wrapping, the blob is unwrapped through
///   the full path and compared before anything is persisted — a device with
///   a broken Keystore fails closed at provisioning, never at read time
///   (Tink's lesson; no silent software fallback).
/// - **Key loss is loud**: a present blob with a missing/unusable KEK (data
///   restored onto a different device — hardware keys never migrate — or
///   OS/OEM eviction, or blob corruption) throws [KeyInvalidated] instead of
///   silently starting an empty store.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'backend.dart';
import 'errors.dart';
import 'ffi/jni.dart';
import 'ffi/posix_file.dart';
import 'key_source.dart';

/// Hardcoded stable Android constants (documented public API values):
/// `KeyProperties.PURPOSE_ENCRYPT | PURPOSE_DECRYPT`.
const int _purposeEncryptDecrypt = 1 | 2;

/// `Cipher.ENCRYPT_MODE` / `Cipher.DECRYPT_MODE`.
const int _encryptMode = 1;
const int _decryptMode = 2;

/// GCM tag length in bits.
const int _gcmTagBits = 128;

const String _strongBoxUnavailable =
    'android/security/keystore/StrongBoxUnavailableException';

/// The wrapped-key blob file name, beside the container.
const String wrappedKeyFileName = 'store-key.wrapped';

// --- wrapped-key blob codec (pure; unit-tested) --------------------------------
//
// 'SKW1' magic (4) | flags u8 (bit0 = KEK created in StrongBox) | ivLen u8 |
// iv | ctLen u16be (2) | ct (ciphertext + GCM tag)

const List<int> _blobMagic = [0x53, 0x4B, 0x57, 0x31]; // 'SKW1'
const int _flagStrongBox = 0x01;
const int _maxIvLen = 32;
const int _maxCtLen = 4096;

/// Decoded wrapped-key blob.
final class WrappedKeyBlob {
  const WrappedKeyBlob(
      {required this.strongBox, required this.iv, required this.ciphertext});
  final bool strongBox;
  final Uint8List iv;

  /// Ciphertext including the GCM tag.
  final Uint8List ciphertext;
}

/// Encodes a wrapped-key blob. Pure.
Uint8List encodeWrappedKeyBlob(WrappedKeyBlob blob) {
  if (blob.iv.isEmpty || blob.iv.length > _maxIvLen) {
    throw ArgumentError('iv length ${blob.iv.length}');
  }
  if (blob.ciphertext.isEmpty || blob.ciphertext.length > _maxCtLen) {
    throw ArgumentError('ciphertext length ${blob.ciphertext.length}');
  }
  final out = BytesBuilder(copy: true)
    ..add(_blobMagic)
    ..addByte(blob.strongBox ? _flagStrongBox : 0)
    ..addByte(blob.iv.length)
    ..add(blob.iv)
    ..addByte(blob.ciphertext.length >> 8)
    ..addByte(blob.ciphertext.length & 0xFF)
    ..add(blob.ciphertext);
  return out.toBytes();
}

/// Decodes a wrapped-key blob; throws [KeyInvalidated] on anything malformed
/// (a corrupt blob means the store key is unrecoverable — same failure class
/// as a lost KEK, distinct from container tamper).
WrappedKeyBlob decodeWrappedKeyBlob(Uint8List bytes) {
  Never malformed() =>
      throw const KeyInvalidated('wrapped store-key blob is malformed');
  if (bytes.length < _blobMagic.length + 2) malformed();
  for (var i = 0; i < _blobMagic.length; i++) {
    if (bytes[i] != _blobMagic[i]) malformed();
  }
  var o = _blobMagic.length;
  final flags = bytes[o++];
  if (flags & ~_flagStrongBox != 0) malformed();
  final ivLen = bytes[o++];
  if (ivLen == 0 || ivLen > _maxIvLen || o + ivLen + 2 > bytes.length) {
    malformed();
  }
  final iv = Uint8List.sublistView(bytes, o, o + ivLen);
  o += ivLen;
  final ctLen = (bytes[o] << 8) | bytes[o + 1];
  o += 2;
  if (ctLen == 0 || ctLen > _maxCtLen || o + ctLen != bytes.length) {
    malformed();
  }
  final ct = Uint8List.sublistView(bytes, o, o + ctLen);
  return WrappedKeyBlob(
      strongBox: flags & _flagStrongBox != 0,
      iv: Uint8List.fromList(iv),
      ciphertext: Uint8List.fromList(ct));
}

// --- the key source ------------------------------------------------------------

/// Wraps the store key with an AndroidKeyStore-held KEK. Composed by the
/// resolver (Android, API 31+); not exported.
final class AndroidKeystoreKeySource implements KeySource {
  AndroidKeystoreKeySource({
    required this.alias,
    required this.blobPath,
    SecureFileSystem fs = const SecureFileSystem(),
  }) : _fs = fs;

  /// The AndroidKeyStore alias of the wrapping key (derived from the appId).
  final String alias;

  /// Where the wrapped blob lives (beside the container; the backend
  /// guarantees the directory exists before [create] runs).
  final String blobPath;

  final SecureFileSystem _fs;

  @override
  Future<Uint8List?> read() async {
    final bytes =
        _fs.readCappedSync(blobPath, maxBytes: 4096, requirePrivate: true);
    if (bytes == null) return null;
    final blob = decodeWrappedKeyBlob(bytes);
    final jni = Jni.instance();
    return jni.withFrame((f) {
      final ks = _loadKeystore(f);
      final kek = _kekOrInvalidated(f, ks);
      try {
        final key = _unwrap(f, kek, blob.iv, blob.ciphertext);
        if (key.length != storeKeyLength) {
          throw const KeyInvalidated('unwrapped store key has wrong length');
        }
        return key;
      } on JavaThrown catch (e) {
        if (f.isThrowableA(e, 'javax/crypto/AEADBadTagException')) {
          throw const KeyInvalidated(
              'store-key unwrap failed authentication — the blob does not '
              'match this device\'s Keystore key (restored data?)');
        }
        rethrow;
      }
    });
  }

  @override
  Future<Uint8List> create() async {
    final key = generateStoreKey();
    final jni = Jni.instance();

    // 1. Ensure the KEK and wrap the key (one frame; StrongBox fallback is
    //    decided here, where the throwable is still frame-local).
    final (iv, ct, strongBox) =
        jni.withFrame<(Uint8List, Uint8List, bool)>((f) {
      final ks = _loadKeystore(f);
      var kek = _getKek(f, ks);
      var usedStrongBox = false;
      if (kek == nullptr) {
        try {
          _generateKek(f, strongBox: true);
          usedStrongBox = true;
        } on JavaThrown catch (e) {
          if (!f.isThrowableA(e, _strongBoxUnavailable)) rethrow;
          _generateKek(f, strongBox: false); // TEE fallback — still hardware
        }
        kek = _getKek(f, ks);
        if (kek == nullptr) {
          throw const KeystoreOperationFailed(
              'AndroidKeyStore did not retain the freshly generated key');
        }
      }
      final (iv, ct) = _wrap(f, kek, key);
      return (iv, ct, usedStrongBox);
    });

    // 2. Self-test: unwrap through the full path before persisting anything.
    final roundTrip = jni.withFrame((f) {
      final ks = _loadKeystore(f);
      final kek = _kekOrInvalidated(f, ks);
      return _unwrap(f, kek, iv, ct);
    });
    var equal = roundTrip.length == key.length;
    if (equal) {
      for (var i = 0; i < key.length; i++) {
        equal = equal && roundTrip[i] == key[i];
      }
    }
    if (!equal) {
      await delete(); // no partial state
      throw const KeystoreOperationFailed(
          'AndroidKeyStore self-test failed: wrap/unwrap round-trip did not '
          'return the original key — refusing to trust this Keystore');
    }

    // 3. Persist the blob (atomic, 0600).
    _fs.writeAtomicSync(
        blobPath,
        encodeWrappedKeyBlob(
            WrappedKeyBlob(strongBox: strongBox, iv: iv, ciphertext: ct)));
    return key;
  }

  @override
  Future<void> delete() async {
    _fs.deleteSync(blobPath);
    final jni = Jni.instance();
    jni.withFrame((f) {
      final ks = _loadKeystore(f);
      final ksCls = f.findClass('java/security/KeyStore');
      final containsAlias =
          f.methodId(ksCls, 'containsAlias', '(Ljava/lang/String;)Z');
      if (f.callBooleanA(ks, containsAlias, [f.str(alias)], 'containsAlias')) {
        final deleteEntry =
            f.methodId(ksCls, 'deleteEntry', '(Ljava/lang/String;)V');
        f.callVoidA(ks, deleteEntry, [f.str(alias)], 'deleteEntry');
      }
    });
  }

  @override
  Future<KeySourceStatus> describe() async {
    final present = _fs.existsSync(blobPath);
    final Jni jni;
    try {
      jni = Jni.instance();
    } on SecretStoreException catch (e) {
      return KeySourceStatus(
          name: 'android-keystore',
          present: present,
          available: false,
          detail: e.message);
    }
    // Report the level the hardware actually claims — measured from the KEK's
    // KeyInfo, never assumed from "Keystore is present". Null until a key
    // exists to measure.
    final level = jni.withFrame(_measureSecurityLevel);
    return KeySourceStatus(
        name: 'android-keystore',
        present: present,
        available: true,
        securityLevel: level,
        detail: level == null
            ? 'AndroidKeyStore (no key yet)'
            : 'AndroidKeyStore AES-256-GCM KEK — ${level.name}');
  }

  /// The KEK's security level per `KeyInfo.getSecurityLevel()` (API 31+):
  /// `TRUSTED_ENVIRONMENT`/`STRONGBOX` → [SecurityLevel.hardwareBacked], else
  /// [SecurityLevel.softwareBacked]. Null when no key exists yet or the query
  /// isn't answerable (diagnostics must never throw).
  SecurityLevel? _measureSecurityLevel(JniFrame f) {
    try {
      final ks = _loadKeystore(f);
      final kek = _getKek(f, ks);
      if (kek == nullptr) return null;
      final keyCls = f.findClass('java/security/Key');
      final getAlgorithm =
          f.methodId(keyCls, 'getAlgorithm', '()Ljava/lang/String;');
      final algo =
          f.callObjectA(kek, getAlgorithm, const [], 'Key.getAlgorithm');
      final skfCls = f.findClass('javax/crypto/SecretKeyFactory');
      final getInstance = f.staticMethodId(skfCls, 'getInstance',
          '(Ljava/lang/String;Ljava/lang/String;)Ljavax/crypto/SecretKeyFactory;');
      final skf = f.callStaticObjectA(skfCls, getInstance,
          [algo, f.str('AndroidKeyStore')], 'SecretKeyFactory.getInstance');
      // A jclass is a java.lang.Class object, usable directly as the argument.
      final keyInfoCls = f.findClass('android/security/keystore/KeyInfo');
      final getKeySpec = f.methodId(skfCls, 'getKeySpec',
          '(Ljavax/crypto/SecretKey;Ljava/lang/Class;)Ljava/security/spec/KeySpec;');
      final keyInfo = f.callObjectA(
          skf, getKeySpec, [kek, keyInfoCls], 'SecretKeyFactory.getKeySpec');
      final getSecurityLevel =
          f.methodId(keyInfoCls, 'getSecurityLevel', '()I');
      final n = f.callIntA(
          keyInfo, getSecurityLevel, const [], 'KeyInfo.getSecurityLevel');
      // KeyProperties: 1 = TRUSTED_ENVIRONMENT, 2 = STRONGBOX.
      return (n == 1 || n == 2)
          ? SecurityLevel.hardwareBacked
          : SecurityLevel.softwareBacked;
    } on JavaThrown {
      return null; // never let a diagnostics query throw
    }
  }

  // --- Keystore choreography (each helper runs inside a caller's frame) ---

  /// `KeyStore.getInstance("AndroidKeyStore")` + `load(null, null)`.
  Pointer<Void> _loadKeystore(JniFrame f) {
    final ksCls = f.findClass('java/security/KeyStore');
    final getInstance = f.staticMethodId(
        ksCls, 'getInstance', '(Ljava/lang/String;)Ljava/security/KeyStore;');
    final ks = f.callStaticObjectA(
        ksCls, getInstance, [f.str('AndroidKeyStore')], 'KeyStore.getInstance');
    final load = f.methodId(ksCls, 'load', '(Ljava/io/InputStream;[C)V');
    f.callVoidA(ks, load, [null, null], 'KeyStore.load');
    return ks;
  }

  /// The KEK, or nullptr when absent.
  Pointer<Void> _getKek(JniFrame f, Pointer<Void> ks) {
    final ksCls = f.findClass('java/security/KeyStore');
    final getKey = f.methodId(
        ksCls, 'getKey', '(Ljava/lang/String;[C)Ljava/security/Key;');
    return f.callObjectA(ks, getKey, [f.str(alias), null], 'KeyStore.getKey');
  }

  /// The KEK, with the key-loss matrix applied: absent or unrecoverable →
  /// [KeyInvalidated] (a blob exists, so this is loud data-loss reporting).
  Pointer<Void> _kekOrInvalidated(JniFrame f, Pointer<Void> ks) {
    final Pointer<Void> kek;
    try {
      kek = _getKek(f, ks);
    } on JavaThrown catch (e) {
      throw KeyInvalidated(
          'the Keystore key for this store is unusable (${e.className}) — '
          'data restored onto a different device, or the OS evicted the key');
    }
    if (kek == nullptr) {
      throw const KeyInvalidated(
          'wrapped store key is present but its Keystore key is missing — '
          'data restored onto a different device, or the OS evicted the key');
    }
    return kek;
  }

  /// Generates the KEK inside AndroidKeyStore.
  void _generateKek(JniFrame f, {required bool strongBox}) {
    final builderCls =
        f.findClass(r'android/security/keystore/KeyGenParameterSpec$Builder');
    const builderSig =
        r'Landroid/security/keystore/KeyGenParameterSpec$Builder;';
    var builder = f.newObject(builderCls, '(Ljava/lang/String;I)V',
        [f.str(alias), _purposeEncryptDecrypt], 'KeyGenParameterSpec.Builder');

    Pointer<Void> chain(String method, String argSig, List<Object?> args) {
      final mid = f.methodId(builderCls, method, '($argSig)$builderSig');
      return f.callObjectA(builder, mid, args, 'Builder.$method');
    }

    builder = chain('setBlockModes', '[Ljava/lang/String;', [
      f.stringArray(const ['GCM'])
    ]);
    builder = chain('setEncryptionPaddings', '[Ljava/lang/String;', [
      f.stringArray(const ['NoPadding'])
    ]);
    builder = chain('setKeySize', 'I', const [256]);
    // The best-case reliability profile: never invalidated by biometric
    // enrollment changes; gate is device-level (the container adds AEAD).
    builder = chain('setUserAuthenticationRequired', 'Z', const [false]);
    if (strongBox) {
      builder = chain('setIsStrongBoxBacked', 'Z', const [true]);
    }
    final build = f.methodId(builderCls, 'build',
        '()Landroid/security/keystore/KeyGenParameterSpec;');
    final spec = f.callObjectA(builder, build, const [], 'Builder.build');

    final kgCls = f.findClass('javax/crypto/KeyGenerator');
    final getInstance = f.staticMethodId(kgCls, 'getInstance',
        '(Ljava/lang/String;Ljava/lang/String;)Ljavax/crypto/KeyGenerator;');
    final kg = f.callStaticObjectA(kgCls, getInstance,
        [f.str('AES'), f.str('AndroidKeyStore')], 'KeyGenerator.getInstance');
    final init = f.methodId(
        kgCls, 'init', '(Ljava/security/spec/AlgorithmParameterSpec;)V');
    f.callVoidA(kg, init, [spec], 'KeyGenerator.init');
    final generateKey =
        f.methodId(kgCls, 'generateKey', '()Ljavax/crypto/SecretKey;');
    f.callObjectA(kg, generateKey, const [], 'KeyGenerator.generateKey');
  }

  /// AES/GCM-wraps [keyBytes] with the KEK; returns (iv, ciphertext+tag).
  (Uint8List, Uint8List) _wrap(
      JniFrame f, Pointer<Void> kek, Uint8List keyBytes) {
    final (cipherCls, cipher) = _newCipher(f);
    final init = f.methodId(cipherCls, 'init', '(ILjava/security/Key;)V');
    f.callVoidA(cipher, init, [_encryptMode, kek], 'Cipher.init(encrypt)');
    final getIv = f.methodId(cipherCls, 'getIV', '()[B');
    final iv =
        f.dartBytes(f.callObjectA(cipher, getIv, const [], 'Cipher.getIV'));
    final doFinal = f.methodId(cipherCls, 'doFinal', '([B)[B');
    final ct = f.dartBytes(f.callObjectA(
        cipher, doFinal, [f.byteArray(keyBytes)], 'Cipher.doFinal(wrap)'));
    return (iv, ct);
  }

  /// Unwraps; a GCM auth failure surfaces as `JavaThrown(AEADBadTagException)`
  /// for the caller to map.
  Uint8List _unwrap(JniFrame f, Pointer<Void> kek, Uint8List iv, Uint8List ct) {
    final (cipherCls, cipher) = _newCipher(f);
    final gcmCls = f.findClass('javax/crypto/spec/GCMParameterSpec');
    final spec = f.newObject(
        gcmCls, '(I[B)V', [_gcmTagBits, f.byteArray(iv)], 'GCMParameterSpec');
    final init = f.methodId(cipherCls, 'init',
        '(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V');
    f.callVoidA(
        cipher, init, [_decryptMode, kek, spec], 'Cipher.init(decrypt)');
    final doFinal = f.methodId(cipherCls, 'doFinal', '([B)[B');
    return f.dartBytes(f.callObjectA(
        cipher, doFinal, [f.byteArray(ct)], 'Cipher.doFinal(unwrap)'));
  }

  (Pointer<Void>, Pointer<Void>) _newCipher(JniFrame f) {
    final cipherCls = f.findClass('javax/crypto/Cipher');
    final getInstance = f.staticMethodId(
        cipherCls, 'getInstance', '(Ljava/lang/String;)Ljavax/crypto/Cipher;');
    final cipher = f.callStaticObjectA(cipherCls, getInstance,
        [f.str('AES/GCM/NoPadding')], 'Cipher.getInstance');
    return (cipherCls, cipher);
  }
}
