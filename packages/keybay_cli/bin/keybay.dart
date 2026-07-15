import 'dart:io';

import 'package:keybay_cli/src/entrypoint.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runKeybay(arguments);
}
