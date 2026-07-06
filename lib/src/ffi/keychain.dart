/// macOS Keychain via the `SecItem` C API (RFC 0005 §5, rev.4).
///
/// Direct Security.framework FFI — no subprocess, no text protocol; secrets
/// move as `CFData`. This is the package's most delicate FFI: CoreFoundation is
/// manually reference-counted, so every `*Create*` is paired with `CFRelease`.
/// Items are created in the classic login keychain
/// (`kSecUseDataProtectionKeychain = false`) and explicitly
/// `kSecAttrSynchronizable = false` (a synchronizable item would escrow the key
/// to iCloud Keychain).
///
/// macOS only. Behind the [KeychainApi] seam so backends are testable with a
/// fake; the real binding is covered by the integration test.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../errors.dart';

/// Result of a keychain reachability probe.
final class KeychainProbe {
  const KeychainProbe(
      {required this.available, required this.locked, this.detail});
  final bool available;
  final bool locked;
  final String? detail;
}

/// Narrow seam over the Keychain: (service, account) → bytes. Implemented by
/// [MacKeychainApi] over FFI and by a fake in tests.
abstract interface class KeychainApi {
  /// The value for (service, account), or null if not found.
  Uint8List? get(String service, String account);

  /// Adds or replaces (service, account) = value, with an optional label.
  void set(String service, String account, Uint8List value, {String? label});

  /// Deletes (service, account). Idempotent (missing is not an error).
  void delete(String service, String account);

  /// Every (account → value) under [service].
  Map<String, Uint8List> getAll(String service);

  /// Whether [service] is reachable and unlocked (best effort).
  KeychainProbe probe(String service);
}

// --- OSStatus values we branch on -------------------------------------------
const int _errSecSuccess = 0;
const int _errSecItemNotFound = -25300;
const int _errSecDuplicateItem = -25299;
const int _errSecAuthFailed = -25293;
const int _errSecInteractionNotAllowed = -25308;
const int _errSecNotAvailable = -25291;

const int _kCFStringEncodingUTF8 = 0x08000100;

typedef _CFTypeRef = Pointer<Void>;
final _CFTypeRef _nullRef = nullptr;

/// The real macOS binding.
final class MacKeychainApi implements KeychainApi {
  MacKeychainApi()
      : _cf = DynamicLibrary.open(
            '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'),
        _sec = DynamicLibrary.open(
            '/System/Library/Frameworks/Security.framework/Security') {
    _bind();
  }

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

  // Security
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _secItemAdd;
  late final int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      _secItemCopyMatching;
  late final int Function(Pointer<Void>, Pointer<Void>) _secItemUpdate;
  late final int Function(Pointer<Void>) _secItemDelete;

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
      _kSecUseDataProtectionKeychain,
      _kCFBooleanTrue,
      _kCFBooleanFalse;

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
    _kSecUseDataProtectionKeychain =
        _cfConst(_sec, 'kSecUseDataProtectionKeychain');
  }

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
      case _errSecAuthFailed:
        throw KeystoreOperationFailed('$op: authorization failed',
            status: status);
      default:
        throw KeystoreOperationFailed('$op failed (OSStatus $status)',
            status: status);
    }
  }

  @override
  Uint8List? get(String service, String account) {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final q = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _kCFBooleanFalse),
        (_kSecReturnData, _kCFBooleanTrue),
        (_kSecMatchLimit, _kSecMatchLimitOne),
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
  void set(String service, String account, Uint8List value, {String? label}) {
    // Try add; on duplicate, update the data (and label).
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final data = _cfData(value)..let(refs.add);
      final labelRef = label == null ? null : (_cfString(label)..let(refs.add));

      final addPairs = <(Pointer<Void>, Pointer<Void>)>[
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecValueData, data),
        (_kSecUseDataProtectionKeychain, _kCFBooleanFalse),
        (_kSecAttrSynchronizable, _kCFBooleanFalse),
        if (labelRef != null) (_kSecAttrLabel, labelRef),
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

      // Update path.
      final query = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _kCFBooleanFalse),
      ]);
      refs.addAll(query.owned);
      final update = _dict([
        (_kSecValueData, data),
        if (labelRef != null) (_kSecAttrLabel, labelRef),
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
  void delete(String service, String account) {
    final refs = <Pointer<Void>>[];
    try {
      final svc = _cfString(service)..let(refs.add);
      final acct = _cfString(account)..let(refs.add);
      final q = _dict([
        (_kSecClass, _kSecClassGenericPassword),
        (_kSecAttrService, svc),
        (_kSecAttrAccount, acct),
        (_kSecUseDataProtectionKeychain, _kCFBooleanFalse),
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
  Map<String, Uint8List> getAll(String service) {
    // The legacy (file) keychain rejects kSecMatchLimitAll + kSecReturnData
    // together (OSStatus -50). Enumerate *attributes only* to collect the
    // account names, then fetch each value with a single-item query.
    final accounts = _accountsUnder(service);
    final result = <String, Uint8List>{};
    for (final account in accounts) {
      final value = get(service, account);
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
        (_kSecUseDataProtectionKeychain, _kCFBooleanFalse),
        (_kSecReturnAttributes, _kCFBooleanTrue),
        (_kSecMatchLimit, _kSecMatchLimitAll),
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
            accounts.add(_copyString(acctRef));
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
  KeychainProbe probe(String service) {
    try {
      get(service, '__secret_store_probe__');
      return const KeychainProbe(available: true, locked: false);
    } on KeystoreLocked catch (e) {
      return KeychainProbe(available: true, locked: true, detail: e.message);
    } on KeystoreUnreachable catch (e) {
      return KeychainProbe(available: false, locked: false, detail: e.message);
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

  /// Converts an (account) CFString back to Dart. Accounts are our own
  /// validated identifiers, so a fixed 1 KiB buffer is ample.
  String _copyString(Pointer<Void> cfString) {
    const cap = 1024;
    final buf = malloc<Uint8>(cap);
    try {
      final ok =
          _cfStringGetCString(cfString, buf, cap, _kCFStringEncodingUTF8);
      if (ok == 0) {
        throw const KeystoreOperationFailed('CFString decode failed');
      }
      var len = 0;
      while (len < cap && buf[len] != 0) {
        len++;
      }
      return utf8.decode(buf.asTypedList(len));
    } finally {
      malloc.free(buf);
    }
  }
}

// Terse `..let(list.add)` for tracking CF refs to release.
extension _Let<T> on T {
  void let(void Function(T) f) => f(this);
}
