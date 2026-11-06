import 'dart:io';

import 'package:gita/cli/gita_cli.dart';

/// `gita` command-line entry point. Build a standalone binary with:
///
///     dart compile exe bin/gita.dart -o build/gita
///
/// Must only import pure-Dart code (no Flutter), or it won't compile.
Future<void> main(List<String> arguments) async {
  exitCode = await GitaCli(out: stdout, err: stderr).run(arguments);
}
