/// Apple Keychain (macOS + iOS) via the `SecItem` C API (see doc/design.md).
///
/// Direct Security.framework FFI — no subprocess, no text protocol; secrets
/// move as `CFData`. This is the package's most delicate FFI: CoreFoundation is
/// manually reference-counted, so every `*Create*` is paired with `CFRelease`.
///
/// Two modes, same code path:
/// - **Login keychain** (`AppleKeychainApi()`, macOS only): the classic
///   file-based keychain (`kSecUseDataProtectionKeychain = false`). Works for
///   any process — unsigned CLIs, `dart run`, signed apps — with no entitlement.
/// - **Data Protection keychain** (`AppleKeychainApi.dataProtection()`):
///   AES-256-GCM + Secure Enclave. On macOS this needs a signed app carrying
///   the Keychain Sharing entitlement — an unentitled process gets
///   `errSecMissingEntitlement` (−34018) → [KeystoreUnreachable] with guidance,
///   never a silent fallback. On iOS it is the only keychain and every app can
///   use it (the implicit default access group). DP items are created
///   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: device-bound (never
///   restored to another device), readable by background work after first
///   unlock — the constant-not-knob accessibility decision
///   (doc/implementation-plan.md Phase 2).
///
/// Both modes set `kSecAttrSynchronizable = false` (a synchronizable item would
/// escrow the key to iCloud Keychain).
///
/// Symbol loading: macOS `dlopen`s the frameworks by absolute path (a plain
/// Dart VM links neither); on iOS every app process already has
/// CoreFoundation/Security loaded, so symbols come from the process image.
///
/// Behind the [KeystoreApi] seam so backends are testable with a fake; the
/// real binding is covered by the integration tests (CLI tier + the Flutter
/// harness in example_flutter/).
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../errors.dart';
import 'keystore_api.dart';

// --- OSStatus values we branch on -------------------------------------------
const int _errSecSuccess = 0;
const int _errSecItemNotFound = -25300;
const int _errSecDuplicateItem = -25299;
const int _errSecAuthFailed = -25293;
const int _errSecInteractionNotAllowed = -25308;
const int _errSecNotAvailable = -25291;
const int _errSecMissingEntitlement = -34018;

const int _kCFStringEncodingUTF8 = 0x08000100;

typedef _CFTypeRef = Pointer<Void>;
final _CFTypeRef _nullRef = nullptr;

/// The probe's own service + account. The service contains a space, which the
/// public `appId` grammar (`[A-Za-z0-9._-]`) can't produce, so the probe item
/// can never collide with — and then delete — a real caller's secret.
///
/// FROZEN: the `secret_store` prefix is a keystore-identity constant that
/// predates the package's rename to `keyway`. It is never rebranded.
const String _dpProbeService = 'secret_store dp-probe';
const String _dpProbeAccount = 'dp-probe';

/// Whether this process can use the Data Protection keychain. Returned by
/// [AppleKeychainApi.probeDataProtection]; the resolver picks the storage
/// scheme from it (macOS only — iOS needs no probe).
enum DataProtectionAvailability {
  /// The DP keychain accepted a write — this process carries the entitlement.
  available,

  /// `errSecMissingEntitlement` (−34018): the *normal* state for unsigned /
  /// unentitled processes (every plain CLI, every `dart run`).
  missingEntitlement,
}

/// The real Apple binding (macOS + iOS).
final class AppleKeychainApi implements KeystoreApi {
  /// The classic file-based login keychain (macOS; no entitlement required).
  AppleKeychainApi() : this._(dataProtection: false);

  /// The Data Protection keychain + Secure Enclave. On macOS: for a signed app
  /// carrying the Keychain Sharing entitlement — fails with
  /// [KeystoreUnreachable] (−34018) on an unentitled process rather than
  /// degrading to the login keychain. On iOS: the only keychain; always
  /// available. See the library-level doc comment.
  AppleKeychainApi.dataProtection() : this._(dataProtection: true);

  AppleKeychainApi._({required bool dataProtection})
      : _dataProtection = dataProtection,
        // iOS: every app process already has these frameworks loaded (UIKit's
        // dependency chain), and absolute-path dlopen is the macOS shape —
        // resolve from the process image instead. macOS: a plain Dart VM
        // links neither framework, so dlopen by absolute path.
        _cf = Platform.isIOS
            ? DynamicLibrary.process()
            : DynamicLibrary.open(
                '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'),
        _sec = Platform.isIOS
            ? DynamicLibrary.process()
            : DynamicLibrary.open(
                '/System/Library/Frameworks/Security.framework/Security') {
    _bind();
  }

  /// When true, target the Data Protection keychain instead of the login
  /// keychain (see the constructors and the library doc comment).
  final bool _dataProtection;

  final DynamicLibrary _cf;
  final DynamicLibrary _sec;

  // CoreFoundation
  late final Pointer<Void> Function(
      Pointer<Void>, Pointer<Uint8>, int, int, int) _cfStringCreateWithBytes;
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int)
      _cfDataCreate;
  late final int Function(Pointer<Void>) _cfDataGetLength;
  late final Pointer<Uint8> Function(Pointer<Void>) _cfDataGetBytePtr;
  late final Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      int,
      Pointer<Void>,
      Pointer<Void>) _cfDictionaryCreate;
  late final void Function(Pointer<Void>) _cfRelease;
  late final int Function(Pointer<Void>) _cfArrayGetCount;
  late final Pointer<Void> Function(Pointer<Void>, int) _cfArrayGetValueAtIndex;
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
      _cfDictionaryGetValue;

  late final Pointer<Void> Function(Pointer<Void>, int, Pointer<Void>)
      _cfNumberCreate;

  // Security
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _secItemAdd;
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      _secItemCopyMatching;
  late final int Function(Pointer<Void>, Pointer<Void>) _secItemUpdate;
  late final int Function(Pointer<Void>) _secItemDelete;

  /// `SecKeyCreateRandomKey(params, error)` — used only by the Secure-Enclave
  /// presence probe.
  late final Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>)
      _secKeyCreateRandomKey;

  // Constant CFStringRef / CFBooleanRef symbols.
  late final Pointer<Void> _keyCallbacks;
  late final Pointer<Void> _valueCallbacks;
  late final _CFTypeRef _kSecClass,
      _kSecClassGenericPassword,
      _kSecAttrService,
      _kSecAttrAccount,
      _kSecAttrLabel,
      _kSecValueData,
      _kSecReturnData,
      _kSecReturnAttributes,
      _kSecMatchLimit,
      _kSecMatchLimitOne,
      _kSecMatchLimitAll,
      _kSecAttrSynchronizable,
      _kSecAttrAccessible,
      _kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      _kSecUseDataProtectionKeychain,
      _kSecUseAuthenticationUI,
      _kSecUseAuthenticationUIFail,
      _kCFBooleanTrue,
      _kCFBooleanFalse,
      // Secure-Enclave presence probe.
      _kSecAttrKeyType,
      _kSecAttrKeyTypeECSECPrimeRandom,
      _kSecAttrKeySizeInBits,
      _kSecAttrTokenID,
      _kSecAttrTokenIDSecureEnclave,
      _kSecPrivateKeyAttrs,
      _kSecAttrIsPermanent;

  void _bind() {
    _cfStringCreateWithBytes = _cf.lookupFunction<
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Uint8>, IntPtr, Uint32, Uint8),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int,
            int)>('CFStringCreateWithBytes');
    _cfDataCreate = _cf.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Uint8>, int)>('CFDataCreate');
    _cfDataGetLength = _cf.lookupFunction<IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CFDataGetLength');
    _cfDataGetBytePtr = _cf.lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)>('CFDataGetBytePtr');
    _cfDictionaryCreate = _cf.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>, IntPtr, Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(
            Pointer<Void>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            int,
            Pointer<Void>,
            Pointer<Void>)>('CFDictionaryCreate');
    _cfRelease = _cf.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('CFRelease');
    _cfArrayGetCount = _cf.lookupFunction<IntPtr Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CFArrayGetCount');
    _cfArrayGetValueAtIndex = _cf.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int)>('CFArrayGetValueAtIndex');
    _cfDictionaryGetValue = _cf.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Void>)>('CFDictionaryGetValue');
    _cfNumberCreate = _cf.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Int32, Pointer<Void>),
        Pointer<Void> Function(
            Pointer<Void>, int, Pointer<Void>)>('CFNumberCreate');

    _secItemAdd = _sec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Pointer<Void>>)>('SecItemAdd');
    _secItemCopyMatching = _sec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(
            Pointer<Void>, Pointer<Pointer<Void>>)>('SecItemCopyMatching');
    _secItemUpdate = _sec.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)>('SecItemUpdate');
    _secItemDelete = _sec.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('SecItemDelete');
    _secKeyCreateRandomKey = _sec.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Pointer<Void>>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Pointer<Void>>)>('SecKeyCreateRandomKey');

    _keyCallbacks = _cf.lookup<Void>('kCFTypeDictionaryKeyCallBacks');
    _valueCallbacks = _cf.lookup<Void>('kCFTypeDictionaryValueCallBacks');
    _kCFBooleanTrue = _cfConst(_cf, 'kCFBooleanTrue');
    _kCFBooleanFalse = _cfConst(_cf, 'kCFBooleanFalse');
    _kSecClass = _cfConst(_sec, 'kSecClass');
    _kSecClassGenericPassword = _cfConst(_sec, 'kSecClassGenericPassword');
    _kSecAttrService = _cfConst(_sec, 'kSecAttrService');
    _kSecAttrAccount = _cfConst(_sec, 'kSecAttrAccount');
    _kSecAttrLabel = _cfConst(_sec, 'kSecAttrLabel');
    _kSecValueData = _cfConst(_sec, 'kSecValueData');
    _kSecReturnData = _cfConst(_sec, 'kSecReturnData');
    _kSecReturnAttributes = _cfConst(_sec, 'kSecReturnAttributes');
    _kSecMatchLimit = _cfConst(_sec, 'kSecMatchLimit');
    _kSecMatchLimitOne = _cfConst(_sec, 'kSecMatchLimitOne');
    _kSecMatchLimitAll = _cfConst(_sec, 'kSecMatchLimitAll');
    _kSecAttrSynchronizable = _cfConst(_sec, 'kSecAttrSynchronizable');
    _kSecAttrAccessible = _cfConst(_sec, 'kSecAttrAccessible');
    _kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly =
        _cfConst(_sec, 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly');
    _kSecUseDataProtectionKeychain =
        _cfConst(_sec, 'kSecUseDataProtectionKeychain');
    _kSecUseAuthenticationUI = _cfConst(_sec, 'kSecUseAuthenticationUI');
    _kSecUseAuthenticationUIFail =
        _cfConst(_sec, 'kSecUseAuthenticationUIFail');
    _kSecAttrKeyType = _cfConst(_sec, 'kSecAttrKeyType');
    _kSecAttrKeyTypeECSECPrimeRandom =
        _cfConst(_sec, 'kSecAttrKeyTypeECSECPrimeRandom');
    _kSecAttrKeySizeInBits = _cfConst(_sec, 'kSecAttrKeySizeInBits');
    _kSecAttrTokenID = _cfConst(_sec, 'kSecAttrTokenID');
    _kSecAttrTokenIDSecureEnclave =
        _cfConst(_sec, 'kSecAttrTokenIDSecureEnclave');
    _kSecPrivateKeyAttrs = _cfConst(_sec, 'kSecPrivateKeyAttrs');
    _kSecAttrIsPermanent = _cfConst(_sec, 'kSecAttrIsPermanent');
  }

  /// Whether this device has a **usable Secure Enclave**, probed by attempting
  /// to create an *ephemeral* (non-persistent) EC key in it. Success proves an
  /// SE mediates the Data Protection keychain's protection here; failure — no
  /// SE (the iOS Simulator, a pre-T2 Intel Mac) or any error — means the DP
  /// keychain falls back to software. The Apple analogue of Android's
  /// `KeyInfo.getSecurityLevel()`.
  ///
  /// **Fail-safe:** any failure returns `false`, so the reported level is
  /// pessimistic ([SecurityLevel.softwareBacked]) rather than an over-claim.
  /// Never throws. The probe key is non-persistent (`kSecAttrIsPermanent`
  /// false), so nothing is stored and there is nothing to clean up.
  bool hasSecureEnclave() {
    const kCFNumberSInt32Type = 3;
    final refs = <Pointer<Void>>[];
    final sizePtr = malloc<Int32>()..value = 256;
    try {
      final size =
          _cfNumberCreate(_nullRef, kCFNumberSInt32Type, sizePtr.cast());
      if (size == nullptr) return false;
      refs.add(size);
      final priv = _dict([(_kSecAttrIsPermanent, _kCFBooleanFalse)]);
      refs.addAll(priv.owned);
      final params = _dict([
        (_kSecAttrKeyType, _kSecAttrKeyTypeECSECPrimeRandom),
        (_kSecAttrKeySizeInBits, size),
        (_kSecAttrTokenID, _kSecAttrTokenIDSecureEnclave),
        (_kSecPrivateKeyAttrs, priv.dict),
      ]);
      refs.addAll(params.owned);
      final key = _secKeyCreateRandomKey(params.dict, nullptr);
      if (key == nullptr) return false;
      _cfRelease(key);
      return true;
    } catch (_) {
      return false;
    } finally {
      malloc.free(sizePtr);
      _releaseAll(refs);
    }
  }

  /// Accessibility for DP-keychain item creation:
  /// `AfterFirstUnlockThisDeviceOnly` — device-bound (never restored to a
  /// different device or backup), readable by background work after first
  /// unlock. Constant, not a knob. Never set on the file-based login keychain
  /// (accessibility is a DP-keychain concept; the legacy store rejects it).
  List<(Pointer<Void>, Pointer<Void>)> get _accessibilityPairs =>
      _dataProtection
          ? [
              (
                _kSecAttrAccessible,
                _kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
              )
            ]
          : const [];

  /// Every SecItem call carries `kSecUseAuthenticationUI =
  /// kSecUseAuthenticationUIFail` — unconditionally, no knob. An operation
  /// that would need user interaction (locked keychain, ACL prompt) fails
  /// fast with `errSecInteractionNotAllowed` → [KeystoreLocked] instead of
  /// raising a GUI dialog. The login keychain auto-unlocks at login, so a
  /// locked keychain is an abnormal state (SSH session, manual lock) where a
  /// typed error beats a prompt that may hang forever; one behavior for every
  /// caller.
  List<(Pointer<Void>, Pointer<Void>)> get _uiPairs =>
      [(_kSecUseAuthenticationUI, _kSecUseAuthenticationUIFail)];

  /// The `kSecUseDataProtectionKeychain` value for the selected mode. Set
  /// explicitly (never omitted) so the target keychain is deterministic —
  /// modern macOS routes a bare query to the DP keychain by default, which
  /// would silently diverge from our intent.
  _CFTypeRef get _dpValue =>
      _dataProtection ? _kCFBooleanTrue : _kCFBooleanFalse;

  // A CFStringRef/CFBooleanRef exported constant: read the pointer stored at the
  // symbol's address.
  _CFTypeRef _cfConst(DynamicLibrary lib, String name) =>
      lib.lookup<Pointer<Void>>(name).value;

  _CFTypeRef _cfString(String s) {
    final bytes = Uint8List.fromList(utf8.encode(s));
    final buf = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      if (bytes.isNotEmpty) {
        buf.asTypedList(bytes.length).setAll(0, bytes);
      }
      final ref = _cfStringCreateWithBytes(
          _nullRef, buf, bytes.length, _kCFStringEncodingUTF8, 0);
      if (ref == nullptr) {
        throw const KeystoreOperationFailed('CFString create failed');
      }
      return ref;
    } finally {
      malloc.free(buf);
    }
  }

  _CFTypeRef _cfData(Uint8List v) {
    final buf = malloc<Uint8>(v.isEmpty ? 1 : v.length);
    try {
      if (v.isNotEmpty) {
        buf.asTypedList(v.length).setAll(0, v);
      }
      final ref = _cfDataCreate(_nullRef, buf, v.length);
      if (ref == nullptr) {
        throw const KeystoreOperationFailed('CFData create failed');
      }
      return ref;
    } finally {
      // Scrub the staging copy of the secret before returning it to the
      // allocator — native memory, unlike the Dart heap, can be zeroed.
      // (CFDataCreate has already taken its own copy.)
      if (v.isNotEmpty) {
        buf.asTypedList(v.length).fillRange(0, v.length, 0);
      }
      malloc.free(buf);
    }
  }

  /// Builds a CFDictionary from [pairs], returning the dict plus every CF ref
  /// that must be released afterwards (the dict retains its own copies).
  ({Pointer<Void> dict, List<Pointer<Void>> owned}) _dict(
      List<(Pointer<Void>, Pointer<Void>)> pairs) {
    final n = pairs.length;
    final keys = malloc<Pointer<Void>>(n);
    final values = malloc<Pointer<Void>>(n);
    try {
      for (var i = 0; i < n; i++) {
        keys[i] = pairs[i].$1;
        values[i] = pairs[i].$2;
      }
      final dict = _cfDictionaryCreate(
          _nullRef, keys, values, n, _keyCallbacks, _valueCallbacks);
      if (dict == nullptr) {
        throw const KeystoreOperationFailed('CFDictionary create failed');
      }
      return (dict: dict, owned: [dict]);
    } finally {
      malloc.free(keys);
      malloc.free(values);
    }
  }

  void _releaseAll(Iterable<Pointer<Void>> refs) {
    for (final r in refs) {
      if (r != nullptr) {
        _cfRelease(r);
      }
    }
  }

  Never _fail(int status, String op) {
    switch (status) {
      case _errSecInteractionNotAllowed:
        throw KeystoreLocked('$op: keychain locked / interaction not allowed');
      case _errSecNotAvailable:
        throw KeystoreUnreachable('$op: keychain not available');
      case _errSecMissingEntitlement:
        throw KeystoreUnreachable(
            '$op: the Data Protection keychain requires a keychain-access-groups '
            'entitlement (Xcode "Keychain Sharing") authorized by a provisioning '
            'profile; it is unavailable to unsigned or unentitled processes '
            '(use AppleKeychainApi() for the login keychain instead)');
      case _errSecAuthFailed:
        throw KeystoreOperationFailed('$op: authorization failed',
            status: status);
      default:
        throw KeystoreOperationFailed('$op failed (OSStatus $status)',
            status: status);
    }
  }

  @override
  Future<Uint8List?> get(String service, String account) async {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final q = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _dpValue),
        (_kSecReturnData, _kCFBooleanTrue),
        (_kSecMatchLimit, _kSecMatchLimitOne),
        ..._uiPairs,
      ]);
      refs.addAll(q.owned);
      final out = malloc<Pointer<Void>>();
      try {
        final status = _secItemCopyMatching(q.dict, out);
        if (status == _errSecItemNotFound) {
          return null;
        }
        if (status != _errSecSuccess) {
          _fail(status, 'get');
        }
        final data = out.value;
        // A stored 0-byte value is present, not absent: some keychains return
        // errSecSuccess with a null data ref (rather than an empty CFData) for
        // it. Treat that as the empty value, never a NULL-deref into CFData.
        if (data == nullptr) {
          return Uint8List(0);
        }
        refs.add(data);
        return _copyData(data);
      } finally {
        malloc.free(out);
      }
    } finally {
      _releaseAll(refs);
    }
  }

  @override
  Future<bool> exists(String service, String account) async {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final q = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _dpValue),
        // Attributes only — never kSecReturnData — so a presence check never
        // pulls the value out of the keychain (nor decrypts it via the Secure
        // Enclave on the DP keychain).
        (_kSecReturnAttributes, _kCFBooleanTrue),
        (_kSecMatchLimit, _kSecMatchLimitOne),
        ..._uiPairs,
      ]);
      refs.addAll(q.owned);
      final out = malloc<Pointer<Void>>();
      try {
        final status = _secItemCopyMatching(q.dict, out);
        if (status == _errSecItemNotFound) {
          return false;
        }
        if (status != _errSecSuccess) {
          _fail(status, 'exists');
        }
        // Success hands back an owned attributes dict (CopyMatching); release
        // it with the rest. Its contents are non-secret and go unread.
        if (out.value != nullptr) {
          refs.add(out.value);
        }
        return true;
      } finally {
        malloc.free(out);
      }
    } finally {
      _releaseAll(refs);
    }
  }

  @override
  Future<void> set(String service, String account, Uint8List value,
      {String? label}) async {
    // Try add; on duplicate, update the data (and label).
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final data = _cfData(value)..let(refs.add);
      // Same default label as the Linux backend, so keystore UIs never show a
      // bare unlabeled item and behavior matches across platforms.
      final labelRef = _cfString(label ?? 'keyway')..let(refs.add);

      final addPairs = <(Pointer<Void>, Pointer<Void>)>[
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecValueData, data),
        (_kSecUseDataProtectionKeychain, _dpValue),
        (_kSecAttrSynchronizable, _kCFBooleanFalse),
        (_kSecAttrLabel, labelRef),
        ..._accessibilityPairs,
        ..._uiPairs,
      ];
      final add = _dict(addPairs);
      refs.addAll(add.owned);
      final status = _secItemAdd(add.dict, nullptr);
      if (status == _errSecSuccess) {
        return;
      }
      if (status != _errSecDuplicateItem) {
        _fail(status, 'set(add)');
      }

      // An existing item must be updated. But `SecItemUpdate` silently ignores
      // a zero-length `kSecValueData` — it returns errSecSuccess while leaving
      // the prior value in place — so an item cannot be updated *to* an empty
      // value that way (verified against the real login keychain). For an empty
      // value, delete the existing item and re-add it, so the stored value is
      // authoritatively empty. (A stored 0-byte value is a legitimate "present
      // but empty", distinct from absent; the re-add takes the default/passed
      // label rather than preserving a prior custom one — an acceptable cost on
      // this rare edge, versus silently keeping stale secret bytes.)
      //
      // Unlike the non-empty update (atomic), this delete-then-add is NOT
      // atomic: if the re-add fails after the delete, the item is left absent,
      // not empty — surfaced as a loud typed error (not silent), and self-heals
      // on retry (add-empty over an absent item succeeds). The keychain offers
      // no atomic set-to-empty, and the value being dropped is the one the
      // caller is replacing anyway, so this is the honest best available.
      if (value.isEmpty) {
        final delQuery = _dict([
          (_kSecClass, _kSecClassGenericPassword),
          (_kSecAttrService, svc),
          (_kSecAttrAccount, acct),
          (_kSecUseDataProtectionKeychain, _dpValue),
          ..._uiPairs,
        ]);
        refs.addAll(delQuery.owned);
        final ds = _secItemDelete(delQuery.dict);
        if (ds != _errSecSuccess && ds != _errSecItemNotFound) {
          _fail(ds, 'set(delete-for-empty)');
        }
        final readd = _dict(addPairs);
        refs.addAll(readd.owned);
        final rs = _secItemAdd(readd.dict, nullptr);
        if (rs != _errSecSuccess) {
          _fail(rs, 'set(re-add-empty)');
        }
        return;
      }

      // Update path (non-empty value).
      final query = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _dpValue),
        ..._uiPairs,
      ]);
      refs.addAll(query.owned);
      // Only rewrite the label when the caller passed one; a value-only update
      // must preserve the item's existing (possibly custom) label rather than
      // reset it to the default.
      final update = _dict([
        (_kSecValueData, data),
        if (label != null) (_kSecAttrLabel, labelRef),
      ]);
      refs.addAll(update.owned);
      final us = _secItemUpdate(query.dict, update.dict);
      if (us != _errSecSuccess) {
        _fail(us, 'set(update)');
      }
    } finally {
      _releaseAll(refs);
    }
  }

  @override
  Future<void> delete(String service, String account) async {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final q = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _dpValue),
        ..._uiPairs,
      ]);
      refs.addAll(q.owned);
      final status = _secItemDelete(q.dict);
      if (status != _errSecSuccess && status != _errSecItemNotFound) {
        _fail(status, 'delete');
      }
    } finally {
      _releaseAll(refs);
    }
  }

  @override
  Future<Map<String, Uint8List>> getAll(String service) async {
    // The legacy (file) keychain rejects kSecMatchLimitAll + kSecReturnData
    // together (OSStatus -50). Enumerate *attributes only* to collect the
    // account names, then fetch each value with a single-item query.
    final accounts = _accountsUnder(service);
    final result = <String, Uint8List>{};
    for (final account in accounts) {
      final value = await get(service, account);
      if (value != null) {
        result[account] = value;
      }
    }
    return result;
  }

  List<String> _accountsUnder(String service) {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final q = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecUseDataProtectionKeychain, _dpValue),
        (_kSecReturnAttributes, _kCFBooleanTrue),
        (_kSecMatchLimit, _kSecMatchLimitAll),
        ..._uiPairs,
      ]);
      refs.addAll(q.owned);
      final out = malloc<Pointer<Void>>();
      try {
        final status = _secItemCopyMatching(q.dict, out);
        if (status == _errSecItemNotFound) {
          return const [];
        }
        if (status != _errSecSuccess) {
          _fail(status, 'getAll');
        }
        final array = out.value;
        refs.add(array);
        final accounts = <String>[];
        final count = _cfArrayGetCount(array);
        for (var i = 0; i < count; i++) {
          final item = _cfArrayGetValueAtIndex(array, i); // borrowed
          final acctRef = _cfDictionaryGetValue(item, _kSecAttrAccount);
          if (acctRef != nullptr) {
            final account = _tryCopyString(acctRef);
            if (account != null) accounts.add(account);
          }
        }
        return accounts;
      } finally {
        malloc.free(out);
      }
    } finally {
      _releaseAll(refs);
    }
  }

  @override
  Future<KeystoreProbe> probe(String service) async {
    try {
      // FROZEN keystore account constant (predates the keyway rename).
      await get(service, '__secret_store_probe__');
      return const KeystoreProbe(available: true, locked: false);
    } on KeystoreLocked catch (e) {
      return KeystoreProbe(available: true, locked: true, detail: e.message);
    } on KeystoreUnreachable catch (e) {
      return KeystoreProbe(available: false, locked: false, detail: e.message);
    } on KeystoreOperationFailed catch (e) {
      // An unexpected OSStatus on the probe read: the keychain API responded,
      // so it is reachable, but something is off. Surface it in `detail`
      // rather than throwing — `probe()` feeds `describe()`, a diagnostics
      // call that must never raise.
      return KeystoreProbe(available: true, locked: false, detail: e.message);
    }
  }

  /// Probes whether this process can write to the Data Protection keychain,
  /// by an add+delete of a tiny probe item under a **dedicated internal
  /// service** ([_dpProbeService]) — never a caller's `appId` — so the probe
  /// can never collide with or delete a real secret. Only meaningful on a
  /// [AppleKeychainApi.dataProtection] instance.
  ///
  /// The raw OSStatus is inspected directly — not the [_fail] mapping — because
  /// the resolver must distinguish precisely: −34018 (missing entitlement) is
  /// the *normal* result for every unentitled process and is **returned**;
  /// any other failure is **thrown** typed and loud, so an entitled app with a
  /// broken keychain setup hears about it instead of being silently downgraded
  /// to weaker storage.
  DataProtectionAvailability probeDataProtection() {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(_dpProbeService)..let(refs.add);
      final acct = _cfString(_dpProbeAccount)..let(refs.add);
      final data = _cfData(Uint8List.fromList(const [0]))..let(refs.add);
      final add = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecValueData, data),
        (_kSecUseDataProtectionKeychain, _dpValue),
        (_kSecAttrSynchronizable, _kCFBooleanFalse),
        ..._accessibilityPairs,
        ..._uiPairs,
      ]);
      refs.addAll(add.owned);
      final status = _secItemAdd(add.dict, nullptr);
      if (status == _errSecMissingEntitlement) {
        return DataProtectionAvailability.missingEntitlement;
      }
      // Duplicate = a leftover probe from a crashed earlier run under our own
      // dedicated service — the write is accepted, which is what the probe
      // asks. Any other nonzero status is a genuine misconfiguration.
      if (status != _errSecSuccess && status != _errSecDuplicateItem) {
        _fail(status, 'dataProtection probe');
      }
      // Remove the probe item. Safe unconditionally: the dedicated service is
      // unreachable by the public appId grammar, so nothing here is ever a
      // caller's secret.
      final del = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _dpValue),
        ..._uiPairs,
      ]);
      refs.addAll(del.owned);
      _secItemDelete(del.dict);
      return DataProtectionAvailability.available;
    } finally {
      _releaseAll(refs);
    }
  }

  Uint8List _copyData(Pointer<Void> data) {
    final len = _cfDataGetLength(data);
    final ptr = _cfDataGetBytePtr(data);
    // Copy out of CF-owned memory into a Dart buffer.
    return Uint8List.fromList(ptr.asTypedList(len));
  }

  late final int Function(Pointer<Void>, Pointer<Uint8>, int, int)
      _cfStringGetCString = _cf.lookupFunction<
          Uint8 Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Uint32),
          int Function(
              Pointer<Void>, Pointer<Uint8>, int, int)>('CFStringGetCString');

  /// Converts an (account) CFString back to Dart, or null when it cannot be
  /// represented (longer than the 1 KiB buffer, or not UTF-8-convertible).
  /// Our own accounts are validated identifiers far below the cap, so null
  /// only ever describes a *foreign* item under the service — enumeration
  /// skips it rather than aborting the whole readAll (the Linux account
  /// parser takes the same stance).
  String? _tryCopyString(Pointer<Void> cfString) {
    const cap = 1024;
    final buf = malloc<Uint8>(cap);
    try {
      final ok =
          _cfStringGetCString(cfString, buf, cap, _kCFStringEncodingUTF8);
      if (ok == 0) {
        return null;
      }
      var len = 0;
      while (len < cap && buf[len] != 0) {
        len++;
      }
      try {
        return utf8.decode(buf.asTypedList(len));
      } on FormatException {
        return null;
      }
    } finally {
      malloc.free(buf);
    }
  }
}

// Terse `..let(list.add)` for tracking CF refs to release.
extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}
