import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'application.dart';

const int _eacces = 13;
const int _enoent = 2;
const int _enoexec = 8;
const int _enotdir = 20;

abstract interface class ExecveSystem {
  int execve({
    required String path,
    required List<String> arguments,
    required Map<String, String> environment,
  });

  int get errno;
}

final class SystemCommandExecutor implements CommandExecutor {
  SystemCommandExecutor({required this.stderr});

  final StringSink stderr;
  PosixCommandExecutor? _delegate;

  @override
  Future<int> execute({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
  }) {
    final delegate = _delegate ??= PosixCommandExecutor(
      system: NativeExecveSystem(),
      stderr: stderr,
    );
    return delegate.execute(
      executable: executable,
      arguments: arguments,
      environment: environment,
    );
  }
}

final class PosixCommandExecutor implements CommandExecutor {
  PosixCommandExecutor({required this.system, required this.stderr});

  final ExecveSystem system;
  final StringSink stderr;

  @override
  Future<int> execute({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
  }) async {
    final argv = <String>[executable, ...arguments];
    if (executable.contains('/')) {
      return _attemptDirect(executable, argv, environment);
    }

    final path = environment['PATH'];
    if (path == null || path.isEmpty) {
      stderr.writeln(
        'error: PATH is absent or empty; use an absolute command path.',
      );
      return 127;
    }

    var sawAccessDenied = false;
    for (final directory in path.split(':')) {
      if (directory.isEmpty) continue;
      final candidate = directory.endsWith('/')
          ? '$directory$executable'
          : '$directory/$executable';
      final result = system.execve(
        path: candidate,
        arguments: argv,
        environment: environment,
      );
      if (result != -1) return _unexpectedReturn(executable);

      switch (system.errno) {
        case _enoent || _enotdir:
          continue;
        case _eacces:
          sawAccessDenied = true;
          continue;
        case _enoexec:
          return _notExecutable(executable);
        case final errno:
          return _otherFailure(executable, errno);
      }
    }

    if (sawAccessDenied) {
      return _notExecutable(executable);
    }
    return _notFound(executable);
  }

  int _attemptDirect(
    String executable,
    List<String> arguments,
    Map<String, String> environment,
  ) {
    final result = system.execve(
      path: executable,
      arguments: arguments,
      environment: environment,
    );
    if (result != -1) return _unexpectedReturn(executable);

    return switch (system.errno) {
      _enoent || _enotdir => _notFound(executable),
      _eacces || _enoexec => _notExecutable(executable),
      final errno => _otherFailure(executable, errno),
    };
  }

  int _notFound(String executable) {
    stderr.writeln('error: command not found: $executable');
    stderr.writeln('Fix PATH or use an absolute command path.');
    return 127;
  }

  int _notExecutable(String executable) {
    stderr.writeln('error: command is not executable: $executable');
    stderr.writeln('Check the command\'s executable permission and format.');
    return 126;
  }

  int _otherFailure(String executable, int errno) {
    stderr.writeln(
      'error: command could not be executed: $executable (errno $errno)',
    );
    stderr.writeln('Check the command path and local filesystem, then retry.');
    return 126;
  }

  int _unexpectedReturn(String executable) {
    stderr.writeln(
      'error: execve returned unexpectedly for $executable; report this bug.',
    );
    return exitSoftware;
  }
}

typedef _NativeExecve =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _DartExecve =
    int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>);
typedef _NativeErrnoLocation = Pointer<Int32> Function();
typedef _DartErrnoLocation = Pointer<Int32> Function();

final class NativeExecveSystem implements ExecveSystem {
  NativeExecveSystem() {
    if (!Platform.isMacOS && !Platform.isLinux) {
      throw UnsupportedError('keybay run supports macOS and Linux only');
    }
    final library = DynamicLibrary.process();
    _execve = library.lookupFunction<_NativeExecve, _DartExecve>('execve');
    final errnoSymbol = Platform.isMacOS ? '__error' : '__errno_location';
    _errnoLocation = library
        .lookupFunction<_NativeErrnoLocation, _DartErrnoLocation>(errnoSymbol);
  }

  late final _DartExecve _execve;
  late final _DartErrnoLocation _errnoLocation;
  int _lastErrno = 0;

  @override
  int get errno => _lastErrno;

  @override
  int execve({
    required String path,
    required List<String> arguments,
    required Map<String, String> environment,
  }) {
    _validateNativeStrings(path, arguments, environment);

    final allocatedStrings = <_NativeString>[];
    final pathPointer = _allocateString(path, allocatedStrings);
    final argumentPointers = _allocateStrings(arguments, allocatedStrings);
    final environmentPointers = _allocateStrings(<String>[
      for (final entry in environment.entries) '${entry.key}=${entry.value}',
    ], allocatedStrings);
    try {
      final result = _execve(
        pathPointer,
        argumentPointers,
        environmentPointers,
      );
      _lastErrno = _errnoLocation().value;
      return result;
    } finally {
      // A successful exec replaces this process image and never reaches here.
      // On failure, overwrite every native staging copy before releasing it;
      // the unavoidable Dart heap copies remain documented by SR-7.
      for (final allocation in allocatedStrings) {
        try {
          allocation.pointer
              .cast<Uint8>()
              .asTypedList(allocation.byteLength + 1)
              .fillRange(0, allocation.byteLength + 1, 0);
        } finally {
          malloc.free(allocation.pointer);
        }
      }
      calloc
        ..free(argumentPointers)
        ..free(environmentPointers);
    }
  }
}

Pointer<Pointer<Utf8>> _allocateStrings(
  List<String> values,
  List<_NativeString> allocatedStrings,
) {
  final pointers = calloc<Pointer<Utf8>>(values.length + 1);
  for (var index = 0; index < values.length; index++) {
    final pointer = _allocateString(values[index], allocatedStrings);
    pointers[index] = pointer;
  }
  pointers[values.length] = nullptr;
  return pointers;
}

Pointer<Utf8> _allocateString(
  String value,
  List<_NativeString> allocatedStrings,
) {
  final pointer = value.toNativeUtf8(allocator: malloc);
  allocatedStrings.add(_NativeString(pointer, pointer.length));
  return pointer;
}

final class _NativeString {
  const _NativeString(this.pointer, this.byteLength);

  final Pointer<Utf8> pointer;
  final int byteLength;
}

void _validateNativeStrings(
  String path,
  List<String> arguments,
  Map<String, String> environment,
) {
  if (path.contains('\u0000')) {
    throw StateError('command path contains NUL');
  }
  for (final argument in arguments) {
    if (argument.contains('\u0000')) {
      throw StateError('command argument contains NUL');
    }
  }
  for (final entry in environment.entries) {
    if (entry.key.contains('=') ||
        entry.key.contains('\u0000') ||
        entry.value.contains('\u0000')) {
      throw StateError('child environment is not representable as envp');
    }
  }
}
