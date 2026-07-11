/// Android JNI over pure `dart:ffi` — no Java shipped, no plugin, no
/// `package:jni` (see doc/design.md §12 and doc/implementation-plan.md
/// Phase 3 for the decision record and the probe that proved it).
///
/// Mechanism: Android officially exports `JNI_GetCreatedJavaVMs` from
/// `libnativehelper` to apps at **API 31+** (android/ndk#1320), so a library
/// dlopen'd by the Dart VM can discover the process JavaVM without
/// `JNI_OnLoad` (which only fires under Java's `System.loadLibrary`). Every
/// class this package touches is a **boot-classpath framework class**
/// (`java.security.KeyStore`, `javax.crypto.Cipher`, …), reachable from a
/// bare attached thread via `FindClass` — which is why the app-classloader
/// bootstrap that keeps `package:jni` a Flutter plugin (dart-lang/native#2997)
/// is not needed here. Below API 31 the symbol does not exist and
/// [Jni.instance] fails closed with a typed, actionable error.
///
/// Scope discipline: this is a private shim for the Android Keystore key
/// source, not a general JNI framework — ~2 dozen `JNIEnv` functions, the
/// same austerity class as the CoreFoundation binding. All `Call*` uses are
/// the `A` (jvalue-array) variants — variadics can't cross FFI. Byte-array
/// staging buffers are zeroed after use (key material passes through them).
/// Java exceptions surface as [JavaThrown] with the class name and message
/// captured eagerly; one escaping a [Jni.withFrame] is converted to a typed
/// [KeystoreOperationFailed]. Off-ramp: when package:jni ships Flutter-free
/// (dart-lang/native#2997), this shim can be re-evaluated behind its seam.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../errors.dart';

// --- JNI constants -----------------------------------------------------------

const int _jniOk = 0;
const int _jniEDetached = -2;
const int _jniVersion16 = 0x00010006;

// JNIInvokeInterface (JavaVM) vtable indices.
const int _vmGetEnv = 6;
const int _vmAttachCurrentThreadAsDaemon = 7;

// JNIEnv vtable indices (jni.h layout — fixed by the JNI spec).
const int _envFindClass = 6;
const int _envExceptionOccurred = 15;
const int _envExceptionClear = 17;
const int _envPushLocalFrame = 19;
const int _envPopLocalFrame = 20;
const int _envNewObjectA = 30;
const int _envGetObjectClass = 31;
const int _envIsInstanceOf = 32;
const int _envGetMethodId = 33;
const int _envCallObjectMethodA = 36;
const int _envCallBooleanMethodA = 39;
const int _envCallIntMethodA = 51;
const int _envCallVoidMethodA = 63;
const int _envGetStaticMethodId = 113;
const int _envCallStaticObjectMethodA = 116;
const int _envNewStringUtf = 167;
const int _envGetStringUtfChars = 169;
const int _envReleaseStringUtfChars = 170;
const int _envGetArrayLength = 171;
const int _envNewObjectArray = 172;
const int _envSetObjectArrayElement = 174;
const int _envNewByteArray = 176;
const int _envGetByteArrayRegion = 200;
const int _envSetByteArrayRegion = 208;
const int _envExceptionCheck = 228;

// --- FFI typedefs -------------------------------------------------------------
//
// `_PFn` stands in for jobject / jclass / jmethodID / jstring — all opaque
// pointers at this layer.

typedef _PFn = Pointer<Void>;

typedef _GetCreatedVMsC = Int32 Function(
    Pointer<Pointer<Void>>, Int32, Pointer<Int32>);
typedef _GetCreatedVMsD = int Function(
    Pointer<Pointer<Void>>, int, Pointer<Int32>);

typedef _VmAttachC = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Void>);
typedef _VmAttachD = int Function(
    Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Void>);
typedef _VmGetEnvC = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>, Int32);
typedef _VmGetEnvD = int Function(Pointer<Void>, Pointer<Pointer<Void>>, int);

typedef _PushFrameC = Int32 Function(Pointer<Void>, Int32);
typedef _PushFrameD = int Function(Pointer<Void>, int);
typedef _PopFrameC = _PFn Function(Pointer<Void>, _PFn);
typedef _ExceptionCheckC = Uint8 Function(Pointer<Void>);
typedef _ExceptionCheckD = int Function(Pointer<Void>);
typedef _VoidOfEnvC = Void Function(Pointer<Void>);
typedef _VoidOfEnvD = void Function(Pointer<Void>);
typedef _ObjOfEnvC = _PFn Function(Pointer<Void>);
typedef _ObjOfObjC = _PFn Function(Pointer<Void>, _PFn);
typedef _IsInstanceOfC = Uint8 Function(Pointer<Void>, _PFn, _PFn);
typedef _IsInstanceOfD = int Function(Pointer<Void>, _PFn, _PFn);
typedef _FindClassC = _PFn Function(Pointer<Void>, Pointer<Utf8>);
typedef _MethodIdC = _PFn Function(
    Pointer<Void>, _PFn, Pointer<Utf8>, Pointer<Utf8>);
typedef _CallObjAC = _PFn Function(Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _CallBoolAC = Uint8 Function(
    Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _CallBoolAD = int Function(Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _CallIntAC = Int32 Function(Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _CallIntAD = int Function(Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _CallVoidAC = Void Function(Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _CallVoidAD = void Function(Pointer<Void>, _PFn, _PFn, Pointer<Uint64>);
typedef _NewStringUtfC = _PFn Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetStringUtfCharsC = Pointer<Utf8> Function(
    Pointer<Void>, _PFn, Pointer<Uint8>);
typedef _ReleaseStringUtfCharsC = Void Function(
    Pointer<Void>, _PFn, Pointer<Utf8>);
typedef _ReleaseStringUtfCharsD = void Function(
    Pointer<Void>, _PFn, Pointer<Utf8>);
typedef _GetArrayLengthC = Int32 Function(Pointer<Void>, _PFn);
typedef _GetArrayLengthD = int Function(Pointer<Void>, _PFn);
typedef _NewObjectArrayC = _PFn Function(Pointer<Void>, Int32, _PFn, _PFn);
typedef _NewObjectArrayD = _PFn Function(Pointer<Void>, int, _PFn, _PFn);
typedef _SetObjectArrayElementC = Void Function(
    Pointer<Void>, _PFn, Int32, _PFn);
typedef _SetObjectArrayElementD = void Function(Pointer<Void>, _PFn, int, _PFn);
typedef _NewByteArrayC = _PFn Function(Pointer<Void>, Int32);
typedef _NewByteArrayD = _PFn Function(Pointer<Void>, int);
typedef _ByteArrayRegionC = Void Function(
    Pointer<Void>, _PFn, Int32, Int32, Pointer<Int8>);
typedef _ByteArrayRegionD = void Function(
    Pointer<Void>, _PFn, int, int, Pointer<Int8>);

/// A pending Java exception, captured and cleared at the JNI boundary.
///
/// [className] and [message] are extracted eagerly (they stay valid anywhere);
/// [throwable] is a **local reference valid only inside the [Jni.withFrame]
/// scope that threw** — use it there (e.g. [JniFrame.isThrowableA]) and never
/// store it. One escaping `withFrame` is converted to
/// [KeystoreOperationFailed] built from the eager strings.
final class JavaThrown implements Exception {
  JavaThrown(this.throwable, this.className, this.message, this.op);

  final Pointer<Void> throwable;
  final String className;
  final String? message;

  /// The operation that raised it (diagnostics; never secret material).
  final String op;

  @override
  String toString() =>
      'JavaThrown($op: $className${message == null ? '' : ': $message'})';
}

/// Process-wide JNI access. [instance] fails closed (typed) below API 31 or
/// off-Android; all use goes through [withFrame].
final class Jni {
  Jni._(this._vm, this._getEnv, this._attach);

  final Pointer<Void> _vm;
  final _VmGetEnvD _getEnv;
  final _VmAttachD _attach;

  static Jni? _cached;

  /// Discovers the process JavaVM via `libnativehelper` (API 31+). Cached for
  /// the process lifetime — there is exactly one VM per Android process.
  static Jni instance() {
    final cached = _cached;
    if (cached != null) return cached;

    final DynamicLibrary lib;
    final _GetCreatedVMsD getCreatedVMs;
    try {
      lib = DynamicLibrary.open('libnativehelper.so');
      getCreatedVMs = lib.lookupFunction<_GetCreatedVMsC, _GetCreatedVMsD>(
          'JNI_GetCreatedJavaVMs');
    } on ArgumentError catch (e) {
      throw KeystoreUnreachable(
          'Android Keystore support needs JNI_GetCreatedJavaVMs from '
          'libnativehelper, which Android exports to apps on Android 12 '
          '(API 31) and newer ($e)');
    }

    final vmOut = calloc<Pointer<Void>>();
    final count = calloc<Int32>();
    try {
      final rc = getCreatedVMs(vmOut, 1, count);
      if (rc != _jniOk || count.value < 1 || vmOut.value == nullptr) {
        throw KeystoreUnreachable(
            'JNI_GetCreatedJavaVMs found no JavaVM (rc=$rc, '
            'count=${count.value})');
      }
      final vm = vmOut.value;
      final table = vm.cast<Pointer<Pointer<Void>>>().value;
      final getEnv = table[_vmGetEnv]
          .cast<NativeFunction<_VmGetEnvC>>()
          .asFunction<_VmGetEnvD>();
      final attach = table[_vmAttachCurrentThreadAsDaemon]
          .cast<NativeFunction<_VmAttachC>>()
          .asFunction<_VmAttachD>();
      return _cached = Jni._(vm, getEnv, attach);
    } finally {
      calloc.free(vmOut);
      calloc.free(count);
    }
  }

  /// The `JNIEnv*` for the current thread, attaching it (as a daemon — it must
  /// never block VM shutdown) if needed. Env pointers are per-thread and never
  /// cached across calls.
  Pointer<Void> _envForCurrentThread() {
    final envOut = calloc<Pointer<Void>>();
    try {
      var rc = _getEnv(_vm, envOut, _jniVersion16);
      if (rc == _jniEDetached) {
        rc = _attach(_vm, envOut, nullptr);
      }
      if (rc != _jniOk || envOut.value == nullptr) {
        throw KeystoreOperationFailed('could not attach to the JavaVM',
            status: rc);
      }
      return envOut.value;
    } finally {
      calloc.free(envOut);
    }
  }

  /// Runs [body] with a [JniFrame] under a JNI local-reference frame
  /// ([capacity] refs), popping the frame afterwards. A [JavaThrown] escaping
  /// [body] is converted to [KeystoreOperationFailed] here (its local
  /// reference dies with the frame; the eager strings carry the diagnosis).
  R withFrame<R>(R Function(JniFrame f) body, {int capacity = 64}) {
    final frame = JniFrame._(_envForCurrentThread());
    if (frame._pushFrame(frame._env, capacity) != _jniOk) {
      throw const KeystoreOperationFailed('PushLocalFrame failed');
    }
    try {
      return body(frame);
    } on JavaThrown catch (e) {
      throw KeystoreOperationFailed('${e.op}: ${e.className}'
          '${e.message == null ? '' : ': ${e.message}'}');
    } finally {
      frame._popFrame(frame._env, nullptr);
      frame._arena.releaseAll();
    }
  }

  /// `System.getProperty(name)` — throws [KeystoreUnreachable] when unset.
  String systemProperty(String name) => withFrame((f) {
        final system = f.findClass('java/lang/System');
        final getProperty = f.staticMethodId(
            system, 'getProperty', '(Ljava/lang/String;)Ljava/lang/String;');
        final value = f.callStaticObjectA(
            system, getProperty, [f.str(name)], 'System.getProperty');
        if (value == nullptr) {
          throw KeystoreUnreachable('System.getProperty($name) is not set');
        }
        return f.dartString(value);
      });
}

/// One attached-thread, one-local-frame view of JNI. Obtained via
/// [Jni.withFrame]; every returned `Pointer<Void>` is a local reference that
/// dies when the frame ends — never store one.
final class JniFrame {
  JniFrame._(this._env) : _arena = Arena() {
    final fns = _env.cast<Pointer<Pointer<Void>>>().value;
    _pushFrame = fns[_envPushLocalFrame]
        .cast<NativeFunction<_PushFrameC>>()
        .asFunction();
    _popFrame =
        fns[_envPopLocalFrame].cast<NativeFunction<_PopFrameC>>().asFunction();
    _exceptionCheck = fns[_envExceptionCheck]
        .cast<NativeFunction<_ExceptionCheckC>>()
        .asFunction<_ExceptionCheckD>();
    _exceptionClear = fns[_envExceptionClear]
        .cast<NativeFunction<_VoidOfEnvC>>()
        .asFunction<_VoidOfEnvD>();
    _exceptionOccurred = fns[_envExceptionOccurred]
        .cast<NativeFunction<_ObjOfEnvC>>()
        .asFunction();
    _getObjectClass =
        fns[_envGetObjectClass].cast<NativeFunction<_ObjOfObjC>>().asFunction();
    _isInstanceOf = fns[_envIsInstanceOf]
        .cast<NativeFunction<_IsInstanceOfC>>()
        .asFunction<_IsInstanceOfD>();
    _findClass =
        fns[_envFindClass].cast<NativeFunction<_FindClassC>>().asFunction();
    _getMethodId =
        fns[_envGetMethodId].cast<NativeFunction<_MethodIdC>>().asFunction();
    _getStaticMethodId = fns[_envGetStaticMethodId]
        .cast<NativeFunction<_MethodIdC>>()
        .asFunction();
    _newObjectA =
        fns[_envNewObjectA].cast<NativeFunction<_CallObjAC>>().asFunction();
    _callObjectA = fns[_envCallObjectMethodA]
        .cast<NativeFunction<_CallObjAC>>()
        .asFunction();
    _callStaticObjectA = fns[_envCallStaticObjectMethodA]
        .cast<NativeFunction<_CallObjAC>>()
        .asFunction();
    _callBooleanA = fns[_envCallBooleanMethodA]
        .cast<NativeFunction<_CallBoolAC>>()
        .asFunction<_CallBoolAD>();
    _callIntA = fns[_envCallIntMethodA]
        .cast<NativeFunction<_CallIntAC>>()
        .asFunction<_CallIntAD>();
    _callVoidA = fns[_envCallVoidMethodA]
        .cast<NativeFunction<_CallVoidAC>>()
        .asFunction<_CallVoidAD>();
    _newStringUtf = fns[_envNewStringUtf]
        .cast<NativeFunction<_NewStringUtfC>>()
        .asFunction();
    _getStringUtfChars = fns[_envGetStringUtfChars]
        .cast<NativeFunction<_GetStringUtfCharsC>>()
        .asFunction();
    _releaseStringUtfChars = fns[_envReleaseStringUtfChars]
        .cast<NativeFunction<_ReleaseStringUtfCharsC>>()
        .asFunction<_ReleaseStringUtfCharsD>();
    _getArrayLength = fns[_envGetArrayLength]
        .cast<NativeFunction<_GetArrayLengthC>>()
        .asFunction<_GetArrayLengthD>();
    _newObjectArray = fns[_envNewObjectArray]
        .cast<NativeFunction<_NewObjectArrayC>>()
        .asFunction<_NewObjectArrayD>();
    _setObjectArrayElement = fns[_envSetObjectArrayElement]
        .cast<NativeFunction<_SetObjectArrayElementC>>()
        .asFunction<_SetObjectArrayElementD>();
    _newByteArray = fns[_envNewByteArray]
        .cast<NativeFunction<_NewByteArrayC>>()
        .asFunction<_NewByteArrayD>();
    _getByteArrayRegion = fns[_envGetByteArrayRegion]
        .cast<NativeFunction<_ByteArrayRegionC>>()
        .asFunction<_ByteArrayRegionD>();
    _setByteArrayRegion = fns[_envSetByteArrayRegion]
        .cast<NativeFunction<_ByteArrayRegionC>>()
        .asFunction<_ByteArrayRegionD>();
  }

  final Pointer<Void> _env;
  final Arena _arena;

  late final _PushFrameD _pushFrame;
  late final _PopFrameC _popFrame;
  late final _ExceptionCheckD _exceptionCheck;
  late final _VoidOfEnvD _exceptionClear;
  late final _ObjOfEnvC _exceptionOccurred;
  late final _ObjOfObjC _getObjectClass;
  late final _IsInstanceOfD _isInstanceOf;
  late final _FindClassC _findClass;
  late final _MethodIdC _getMethodId;
  late final _MethodIdC _getStaticMethodId;
  late final _CallObjAC _newObjectA;
  late final _CallObjAC _callObjectA;
  late final _CallObjAC _callStaticObjectA;
  late final _CallBoolAD _callBooleanA;
  late final _CallIntAD _callIntA;
  late final _CallVoidAD _callVoidA;
  late final _NewStringUtfC _newStringUtf;
  late final _GetStringUtfCharsC _getStringUtfChars;
  late final _ReleaseStringUtfCharsD _releaseStringUtfChars;
  late final _GetArrayLengthD _getArrayLength;
  late final _NewObjectArrayD _newObjectArray;
  late final _SetObjectArrayElementD _setObjectArrayElement;
  late final _NewByteArrayD _newByteArray;
  late final _ByteArrayRegionD _getByteArrayRegion;
  late final _ByteArrayRegionD _setByteArrayRegion;

  // --- exceptions ---

  bool _pending() => _exceptionCheck(_env) != 0;

  /// If a Java exception is pending: capture class name + message, clear it,
  /// and throw [JavaThrown]. Called after every JNI call that can raise.
  void _check(String op) {
    if (!_pending()) return;
    final occurred = _exceptionOccurred(_env); // local ref
    _exceptionClear(_env);
    var className = 'unknown';
    String? message;
    // Best-effort extraction; never let diagnostics itself throw.
    try {
      final cls = _getObjectClass(_env, occurred);
      final getName =
          methodId(cls, 'getName', '()Ljava/lang/String;', quiet: true);
      if (getName != nullptr) {
        final nameObj =
            _callObjectA(_env, occurred, getName, _jvalues(const []));
        if (!_pending() && nameObj != nullptr) {
          className = dartString(nameObj);
        }
        if (_pending()) _exceptionClear(_env);
      }
      final getMessage =
          methodId(cls, 'getMessage', '()Ljava/lang/String;', quiet: true);
      if (getMessage != nullptr) {
        final msgObj =
            _callObjectA(_env, occurred, getMessage, _jvalues(const []));
        if (!_pending() && msgObj != nullptr) {
          message = dartString(msgObj);
        }
        if (_pending()) _exceptionClear(_env);
      }
    } catch (_) {
      // fall through with whatever was extracted
    }
    throw JavaThrown(occurred, className, message, op);
  }

  /// Whether [thrown]'s throwable (still frame-local) is an instance of
  /// [slashClassName]. False when the class itself is missing on this device.
  bool isThrowableA(JavaThrown thrown, String slashClassName) {
    final cls = _findClassOrNull(slashClassName);
    if (cls == nullptr) return false;
    return _isInstanceOf(_env, thrown.throwable, cls) != 0;
  }

  // --- classes & methods ---

  Pointer<Void> _findClassOrNull(String slashName) {
    final cls = _findClass(_env, slashName.toNativeUtf8(allocator: _arena));
    if (_pending()) {
      _exceptionClear(_env);
      return nullptr;
    }
    return cls;
  }

  /// Finds a boot-classpath class; throws typed if absent.
  Pointer<Void> findClass(String slashName) {
    final cls = _findClassOrNull(slashName);
    if (cls == nullptr) {
      throw KeystoreOperationFailed('Java class not found: $slashName');
    }
    return cls;
  }

  Pointer<Void> methodId(Pointer<Void> cls, String name, String sig,
      {bool quiet = false}) {
    final id = _getMethodId(_env, cls, name.toNativeUtf8(allocator: _arena),
        sig.toNativeUtf8(allocator: _arena));
    if (_pending()) {
      _exceptionClear(_env);
      if (quiet) return nullptr;
      throw KeystoreOperationFailed('Java method not found: $name$sig');
    }
    return id;
  }

  Pointer<Void> staticMethodId(Pointer<Void> cls, String name, String sig) {
    final id = _getStaticMethodId(
        _env,
        cls,
        name.toNativeUtf8(allocator: _arena),
        sig.toNativeUtf8(allocator: _arena));
    if (_pending()) {
      _exceptionClear(_env);
      throw KeystoreOperationFailed('Java static method not found: $name$sig');
    }
    return id;
  }

  // --- jvalue packing ---
  //
  // jvalue is a 64-bit union. Supported argument kinds: Pointer<Void>
  // (jobject; nullptr or Dart null for Java null), int (jint), bool
  // (jboolean).

  Pointer<Uint64> _jvalues(List<Object?> args) {
    final out = _arena<Uint64>(args.isEmpty ? 1 : args.length);
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      out[i] = switch (a) {
        null => 0,
        final Pointer<Void> p => p.address,
        final int v => v.toUnsigned(32),
        final bool b => b ? 1 : 0,
        _ => throw ArgumentError(
            'unsupported JNI argument type: ${a.runtimeType}'),
      };
    }
    return out;
  }

  // --- calls (A-variants only) ---

  /// Instance call returning an object (nullptr = Java null).
  Pointer<Void> callObjectA(
      Pointer<Void> recv, Pointer<Void> mid, List<Object?> args, String op) {
    final r = _callObjectA(_env, recv, mid, _jvalues(args));
    _check(op);
    return r;
  }

  Pointer<Void> callStaticObjectA(
      Pointer<Void> cls, Pointer<Void> mid, List<Object?> args, String op) {
    final r = _callStaticObjectA(_env, cls, mid, _jvalues(args));
    _check(op);
    return r;
  }

  bool callBooleanA(
      Pointer<Void> recv, Pointer<Void> mid, List<Object?> args, String op) {
    final r = _callBooleanA(_env, recv, mid, _jvalues(args));
    _check(op);
    return r != 0;
  }

  int callIntA(
      Pointer<Void> recv, Pointer<Void> mid, List<Object?> args, String op) {
    final r = _callIntA(_env, recv, mid, _jvalues(args));
    _check(op);
    return r;
  }

  void callVoidA(
      Pointer<Void> recv, Pointer<Void> mid, List<Object?> args, String op) {
    _callVoidA(_env, recv, mid, _jvalues(args));
    _check(op);
  }

  /// `new cls(...)` via the constructor with [ctorSig].
  Pointer<Void> newObject(
      Pointer<Void> cls, String ctorSig, List<Object?> args, String op) {
    final ctor = methodId(cls, '<init>', ctorSig);
    final r = _newObjectA(_env, cls, ctor, _jvalues(args));
    _check(op);
    if (r == nullptr) {
      throw KeystoreOperationFailed('$op returned null');
    }
    return r;
  }

  // --- strings ---

  /// A Java string (local ref) from a Dart string.
  Pointer<Void> str(String s) {
    final r = _newStringUtf(_env, s.toNativeUtf8(allocator: _arena));
    _check('NewStringUTF');
    if (r == nullptr) {
      throw const KeystoreOperationFailed('NewStringUTF returned null');
    }
    return r;
  }

  /// Dart copy of a Java string.
  String dartString(Pointer<Void> jstr) {
    final chars = _getStringUtfChars(_env, jstr, nullptr);
    if (chars == nullptr) {
      throw const KeystoreOperationFailed('GetStringUTFChars failed');
    }
    try {
      return chars.toDartString();
    } finally {
      _releaseStringUtfChars(_env, jstr, chars);
    }
  }

  /// A `String[]` (local ref) from Dart strings.
  Pointer<Void> stringArray(List<String> values) {
    final stringCls = findClass('java/lang/String');
    final arr = _newObjectArray(_env, values.length, stringCls, nullptr);
    _check('NewObjectArray');
    for (var i = 0; i < values.length; i++) {
      _setObjectArrayElement(_env, arr, i, str(values[i]));
      _check('SetObjectArrayElement');
    }
    return arr;
  }

  // --- byte arrays (staging buffers zeroed — key material passes through) ---

  /// A `byte[]` (local ref) holding [bytes].
  Pointer<Void> byteArray(Uint8List bytes) {
    final arr = _newByteArray(_env, bytes.length);
    _check('NewByteArray');
    if (arr == nullptr) {
      throw const KeystoreOperationFailed('NewByteArray returned null');
    }
    if (bytes.isEmpty) return arr;
    final buf = _arena<Int8>(bytes.length);
    buf.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    _setByteArrayRegion(_env, arr, 0, bytes.length, buf);
    buf.cast<Uint8>().asTypedList(bytes.length).fillRange(0, bytes.length, 0);
    _check('SetByteArrayRegion');
    return arr;
  }

  /// Dart copy of a Java `byte[]`.
  Uint8List dartBytes(Pointer<Void> jarr, {int maxBytes = 1 << 16}) {
    final len = _getArrayLength(_env, jarr);
    _check('GetArrayLength');
    if (len < 0 || len > maxBytes) {
      throw KeystoreOperationFailed('unexpected Java byte[] length: $len');
    }
    if (len == 0) return Uint8List(0);
    final buf = _arena<Int8>(len);
    _getByteArrayRegion(_env, jarr, 0, len, buf);
    _check('GetByteArrayRegion');
    final view = buf.cast<Uint8>().asTypedList(len);
    final out = Uint8List.fromList(view);
    view.fillRange(0, len, 0);
    return out;
  }
}
