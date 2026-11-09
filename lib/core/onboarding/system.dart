/// Ports the onboarding steps use to reach the machine, so every step can be
/// tested with fakes. Pure Dart: no Flutter imports (the CLI is compiled with
/// `dart compile exe`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a finished program left behind.
class CommandResult {
  const CommandResult(this.exitCode, {this.stdout = '', this.stderr = ''});

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;

  /// Exit code used when the program could not be started at all
  /// (not installed, not on PATH, not allowed to run).
  static const notFound = 9009;

  /// Exit code used when the program ran past its time limit and was stopped.
  static const timedOut = 124;
}

/// How a program's input and output are connected.
enum CommandIo {
  /// Output is captured and returned; input is empty. For checks and queries.
  capture,

  /// Output goes straight to the terminal so the person sees it; input is
  /// empty. For installers and setup scripts that ask nothing.
  show,

  /// Input and output are the terminal's. Only for commands that must ask the
  /// person something themselves (sudo's password, `gh auth logout`).
  terminal,
}

/// Environment for starting Windows PowerShell (`powershell`, 5.1).
///
/// When Gita itself was started from PowerShell 7, PSModulePath points at
/// PowerShell 7's modules, and Windows PowerShell started with it can't load
/// its own built-in commands (for example "Get-FileHash is not recognized",
/// which breaks the official Claude Code installer). Without the variable,
/// Windows PowerShell builds its default module path.
const windowsPowerShellEnvironment = <String, String?>{'PSModulePath': null};

/// Runs other programs.
abstract interface class CommandRunner {
  /// Runs [executable] with [arguments]. Never throws for a program that is
  /// missing or fails: that comes back as a [CommandResult] with a non-zero
  /// exit code ([CommandResult.notFound] when it couldn't start).
  ///
  /// [environment] entries are added to (and override) the current
  /// environment; a `null` value removes that variable for the child.
  /// [stdinText] is written to the program's input (only with
  /// [CommandIo.capture]).
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    CommandIo io = CommandIo.capture,
    Map<String, String?> environment = const {},
    String? workingDirectory,
    String? stdinText,
    Duration timeout = const Duration(minutes: 2),
  });
}

/// Asks the person things. With no terminal, every question returns its
/// default and [interactive] is false.
abstract interface class Prompter {
  bool get interactive;

  /// Asks for a line of text; an empty answer gives [defaultValue].
  Future<String> ask(String question, {String defaultValue = ''});

  /// Asks a yes/no question; an empty answer gives [defaultYes].
  Future<bool> confirm(String question, {required bool defaultYes});
}

/// Where onboarding writes what it is doing. Kept apart from the steps so the
/// CLI can print plain text or JSON.
abstract interface class Reporter {
  /// A new section, e.g. "Installing Gita".
  void say(String text);

  /// Detail under the current section.
  void note(String text);

  /// Something the person should notice; the run continues.
  void warn(String text);
}

/// [CommandRunner] backed by `dart:io`.
class SystemCommandRunner implements CommandRunner {
  const SystemCommandRunner();

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    CommandIo io = CommandIo.capture,
    Map<String, String?> environment = const {},
    String? workingDirectory,
    String? stdinText,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final removed = [
      for (final e in environment.entries)
        if (e.value == null) e.key,
    ];
    final env = <String, String>{
      for (final e in Platform.environment.entries)
        if (!removed.any((r) => _sameVar(r, e.key))) e.key: e.value,
      for (final e in environment.entries)
        if (e.value != null) e.key: e.value!,
    };
    final mode = switch (io) {
      CommandIo.capture => ProcessStartMode.normal,
      CommandIo.show => ProcessStartMode.normal,
      CommandIo.terminal => ProcessStartMode.inheritStdio,
    };
    Future<Process> start(String exe, {required bool shell}) => Process.start(
      exe,
      arguments,
      environment: env,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
      runInShell: shell,
      mode: mode,
    );
    Process process;
    try {
      // Never through cmd.exe by default: it would read characters such as
      // | & % ^ in arguments (git setting names, gh text) as shell syntax.
      process = await start(executable, shell: false);
    } on ProcessException catch (e) {
      // A .cmd/.bat program (some installers add one instead of an .exe) can
      // only start through cmd.exe; allow that only for plain arguments.
      final shim = Platform.isWindows ? windowsShim(executable, env['PATH'] ?? env['Path'] ?? '') : null;
      if (shim == null || !arguments.every(safeForCmd)) {
        return CommandResult(CommandResult.notFound, stderr: e.message);
      }
      try {
        process = await start(shim, shell: true);
      } on ProcessException catch (e2) {
        return CommandResult(CommandResult.notFound, stderr: e2.message);
      }
    }

    final out = StringBuffer();
    final errOut = StringBuffer();
    final pending = <Future<void>>[];
    if (io != CommandIo.terminal) {
      if (stdinText != null && io == CommandIo.capture) {
        process.stdin.write(stdinText);
      }
      unawaited(process.stdin.close().catchError((Object _) {}));
      void pipe(Stream<List<int>> s, StringBuffer into, IOSink? echo) {
        pending.add(
          s.transform(const Utf8Decoder(allowMalformed: true)).forEach((chunk) {
            into.write(chunk);
            echo?.write(chunk);
          }),
        );
      }

      pipe(process.stdout, out, io == CommandIo.show ? stdout : null);
      pipe(process.stderr, errOut, io == CommandIo.show ? stderr : null);
    }

    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return CommandResult.timedOut;
      },
    );
    await Future.wait(pending).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    return CommandResult(code, stdout: out.toString(), stderr: errOut.toString());
  }

  static bool _sameVar(String a, String b) => Platform.isWindows ? a.toUpperCase() == b.toUpperCase() : a == b;

  /// The full path of a `.cmd` or `.bat` program called [name] on [path]
  /// (Windows), or null. Only plain names are looked up.
  static String? windowsShim(String name, String path) {
    if (name.contains('/') || name.contains(r'\') || name.contains('.')) return null;
    for (final dir in path.split(';')) {
      if (dir.trim().isEmpty) continue;
      for (final ext in const ['.cmd', '.bat']) {
        final f = File('${dir.trim()}\\$name$ext');
        if (f.existsSync()) return f.path;
      }
    }
    return null;
  }

  /// Whether [arg] can go through cmd.exe without being read as shell syntax.
  static bool safeForCmd(String arg) => !arg.runes.any((r) => r < 0x20 || '%^|<>&"!()'.runes.contains(r));
}

/// [Prompter] that reads the terminal.
class TerminalPrompter implements Prompter {
  TerminalPrompter({required this.out, bool? interactive})
    : interactive = interactive ?? (stdin.hasTerminal && stdout.hasTerminal);

  final StringSink out;

  @override
  final bool interactive;

  @override
  Future<String> ask(String question, {String defaultValue = ''}) async {
    if (!interactive) return defaultValue;
    out.write(defaultValue.isEmpty ? '$question: ' : '$question [$defaultValue]: ');
    final line = stdin.readLineSync(encoding: utf8)?.trim() ?? '';
    return line.isEmpty ? defaultValue : line;
  }

  @override
  Future<bool> confirm(String question, {required bool defaultYes}) async {
    if (!interactive) return defaultYes;
    while (true) {
      out.write('$question ${defaultYes ? '[Y/n]' : '[y/N]'} ');
      final line = (stdin.readLineSync(encoding: utf8) ?? '').trim().toLowerCase();
      if (line.isEmpty) return defaultYes;
      if (line == 'y' || line == 'yes') return true;
      if (line == 'n' || line == 'no') return false;
    }
  }
}
