import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

// Mirrors the core's maximum sealed-container envelope. A value at this limit
// still cannot fit once container overhead is added, so rejecting limit + 1
// bytes cannot exclude any value the backing store could persist.
const int maxSecretInputBytes = 16 * 1024 * 1024;

final class SecretInputException implements Exception {
  const SecretInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class TerminalControl {
  bool get hasTerminal;
  bool get echoMode;
  set echoMode(bool value);
}

final class SecretInputReader {
  SecretInputReader({
    required this.input,
    required this.terminal,
    required this.stderr,
    this.managePosixSignals = false,
  });

  factory SecretInputReader.system({
    required Stdin stdin,
    required StringSink stderr,
  }) => SecretInputReader(
    input: stdin,
    terminal: _StdinTerminalControl(stdin),
    stderr: stderr,
    managePosixSignals: true,
  );

  final Stream<List<int>> input;
  final TerminalControl terminal;
  final StringSink stderr;
  final bool managePosixSignals;

  Future<String> read({required String key, required bool fromStdin}) async {
    if (fromStdin) {
      // The mirror of the interactive branch's TTY requirement below. Typing
      // into `--stdin` at a terminal would echo the secret into the terminal
      // and its scrollback — exactly the casual disclosure the threat model
      // rules out — so the piped mode refuses a terminal rather than reading
      // from it. (Redirected input — a pipe, file, or heredoc — is never a
      // terminal, so every automation shape still works.)
      if (terminal.hasTerminal) {
        throw const SecretInputException(
          '--stdin expects piped input but stdin is a terminal; drop --stdin '
          'to be prompted with input hidden',
        );
      }
      return decodeSecretBytes(await _readToEnd(input));
    }
    if (!terminal.hasTerminal) {
      throw const SecretInputException(
        'interactive set requires a TTY; pipe the value to keybay set '
        '--stdin instead',
      );
    }

    final previousEchoMode = terminal.echoMode;
    final signalGuard = managePosixSignals
        ? _PromptSignalGuard(terminal, previousEchoMode)
        : null;
    StreamSubscription<List<int>>? lineSubscription;
    try {
      // Install the guards while echo is still in its original state. If a
      // signal lands anywhere after echo is disabled, a handler is already in
      // place to restore it (or the fail-safe disposition is already active).
      signalGuard?.start();
      terminal.echoMode = false;
      stderr.write('Value for $key (input hidden): ');
      final line = await _readOneLine(input);
      lineSubscription = line.subscription;
      stderr.writeln();
      return decodeSecretBytes(line.bytes);
    } finally {
      // Every cleanup action must run even if an earlier one fails. A terminal
      // can disappear while input is pending; a failed echo restoration must
      // not leave the temporary signal dispositions or stdin subscription
      // installed for the remainder of the process.
      try {
        terminal.echoMode = previousEchoMode;
      } finally {
        try {
          await signalGuard?.close();
        } finally {
          await lineSubscription?.cancel();
        }
      }
    }
  }
}

String decodeSecretBytes(List<int> bytes) {
  if (bytes.length > maxSecretInputBytes) {
    throw const SecretInputException(
      'secret input exceeds Keybay\'s 16 MiB store envelope; store a '
      'credential rather than a blob',
    );
  }
  late final String value;
  try {
    value = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const SecretInputException(
      'secret input is not valid UTF-8; provide a UTF-8 text value',
    );
  }
  if (value.contains('\u0000')) {
    throw const SecretInputException(
      'secret input contains a NUL character; provide text without NUL',
    );
  }
  final stripped = switch (value) {
    _ when value.endsWith('\r\n') => value.substring(0, value.length - 2),
    _ when value.endsWith('\n') => value.substring(0, value.length - 1),
    _ => value,
  };
  // An empty read is a failed producer (`op read … | keybay set --stdin` with
  // the producer printing nothing exits 0 without pipefail), or a bare Enter
  // at the prompt — not a credential. Storing it would silently replace a real
  // value with the empty string, so it fails loudly instead. A genuine 0-byte
  // value remains expressible through the bytes-first library API.
  if (stripped.isEmpty) {
    throw const SecretInputException(
      'secret input is empty; refusing to store an empty value (a failed '
      'producer in a pipeline must not silently replace a stored secret)',
    );
  }
  return stripped;
}

Future<Uint8List> _readToEnd(Stream<List<int>> input) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in input) {
    final remaining = maxSecretInputBytes + 1 - bytes.length;
    if (chunk.length >= remaining) {
      bytes.add(chunk.sublist(0, remaining));
      break;
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

final class _LineRead {
  const _LineRead(this.bytes, this.subscription);

  final Uint8List bytes;
  final StreamSubscription<List<int>> subscription;
}

Future<_LineRead> _readOneLine(Stream<List<int>> input) {
  final bytes = BytesBuilder(copy: false);
  final completer = Completer<_LineRead>();
  // Ownership is transferred in _LineRead and cancelled by SecretInputReader
  // only after terminal echo has been restored.
  // ignore: cancel_subscriptions
  late final StreamSubscription<List<int>> subscription;
  subscription = input.listen(
    (chunk) {
      if (completer.isCompleted) return;
      final newline = chunk.indexOf(0x0a);
      final remaining = maxSecretInputBytes + 1 - bytes.length;
      if (newline == -1 && chunk.length >= remaining) {
        bytes.add(chunk.sublist(0, remaining));
        subscription.pause();
        completer.complete(_LineRead(bytes.takeBytes(), subscription));
        return;
      }
      if (newline == -1) {
        bytes.add(chunk);
        return;
      }
      final lineLength = newline + 1;
      bytes.add(
        chunk.sublist(0, lineLength < remaining ? lineLength : remaining),
      );
      subscription.pause();
      completer.complete(_LineRead(bytes.takeBytes(), subscription));
    },
    onError: completer.completeError,
    onDone: () {
      if (!completer.isCompleted) {
        completer.complete(_LineRead(bytes.takeBytes(), subscription));
      }
    },
  );
  return completer.future;
}

final class _StdinTerminalControl implements TerminalControl {
  _StdinTerminalControl(this.stdin);

  final Stdin stdin;

  @override
  bool get hasTerminal => stdin.hasTerminal;

  @override
  bool get echoMode => stdin.echoMode;

  @override
  set echoMode(bool value) => stdin.echoMode = value;
}

final class _PromptSignalGuard {
  _PromptSignalGuard(this.terminal, this.previousEchoMode);

  final TerminalControl terminal;
  final bool previousEchoMode;
  final List<StreamSubscription<ProcessSignal>> _subscriptions =
      <StreamSubscription<ProcessSignal>>[];
  late final _IgnoredSignalGuard _failSafeSignalGuard = _IgnoredSignalGuard(
    <int>[
      ProcessSignal.sigquit.signalNumber,
      ProcessSignal.sigtstp.signalNumber,
    ],
  );

  void start() {
    _watchTermination(ProcessSignal.sigint, 130);
    _watchTermination(ProcessSignal.sigterm, 143);
    _watchTermination(ProcessSignal.sighup, 129);
    _failSafeSignalGuard.start();
  }

  void _watchTermination(ProcessSignal signal, int status) {
    _subscriptions.add(
      signal.watch().listen((_) {
        _restoreEcho();
        exit(status);
      }),
    );
  }

  void _restoreEcho() {
    try {
      terminal.echoMode = previousEchoMode;
    } on Object {
      // Best effort on a terminal that disappeared while handling a signal.
    }
  }

  Future<void> close() async {
    _failSafeSignalGuard.close();
    await Future.wait(<Future<void>>[
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
  }
}

typedef _NativeSignal = Pointer<Void> Function(Int32, Pointer<Void>);
typedef _DartSignal = Pointer<Void> Function(int, Pointer<Void>);

/// Dart does not expose SIGQUIT or job-control signal streams on macOS.
/// Ignoring them only while the prompt owns the terminal is the fail-safe
/// temporary behavior: neither can strand echo disabled. The owner ratified
/// this austere contract instead of adding a native signal bridge solely for
/// the short hidden-input window (implementation plan §15).
final class _IgnoredSignalGuard {
  _IgnoredSignalGuard(this.signalNumbers);

  final List<int> signalNumbers;
  _DartSignal? _signal;
  final Map<int, Pointer<Void>> _previous = <int, Pointer<Void>>{};

  void start() {
    final signal = DynamicLibrary.process()
        .lookupFunction<_NativeSignal, _DartSignal>('signal');
    _signal = signal;
    for (final signalNumber in signalNumbers) {
      _previous[signalNumber] = signal(
        signalNumber,
        Pointer<Void>.fromAddress(1),
      );
    }
  }

  void close() {
    final signal = _signal;
    if (signal != null) {
      for (final entry in _previous.entries) {
        signal(entry.key, entry.value);
      }
    }
    _signal = null;
    _previous.clear();
  }
}
