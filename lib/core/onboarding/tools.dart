/// Checks, installs or repairs the developer tools `gita onboard` needs: Git,
/// GitHub CLI, Claude Code and, on Linux, secret-tool (Gita keeps tokens in
/// the system keyring through it).
///
/// Pure Dart: no Flutter imports (the CLI is compiled with `dart compile exe`).
/// Every program is started through [CommandRunner] with a fixed executable
/// and an argument list; nothing is ever built into a shell string from data.
library;

import 'dart:io' show Platform;

import 'onboarding_file.dart' show ToolNeed;
import 'system.dart';

/// The operating system the tools are installed on.
enum HostOs { windows, macos, linux }

/// Result of one tool, shown as a summary row.
class ToolOutcome {
  /// Creates an outcome; [failed] only for a required tool that doesn't work.
  const ToolOutcome(this.summary, {this.failed = false, this.hint});

  /// Short result: 'skipped', 'not needed', 'already installed', 'installed',
  /// 'reinstalled', 'dry run', 'not installed (optional)' or 'failed'.
  final String summary;

  /// True only when a required tool couldn't be made to work.
  final bool failed;

  /// What the person should do, when the tool failed or was left out.
  final String? hint;

  @override
  String toString() => 'ToolOutcome($summary, failed: $failed, hint: $hint)';
}

/// Makes sure each developer tool is installed and runs, installing or
/// reinstalling it with the system's usual installer when it doesn't.
class ToolInstaller {
  /// Creates an installer for [os] that runs programs with `runner`, reports
  /// through `reporter` and asks through `prompter`. [homeDir] is the person's home folder
  /// (Claude Code installs into `<home>/.local/bin`). With [dryRun], checks
  /// still run but no installer or sudo is started. [environment] is only
  /// read on Windows to find `ProgramFiles` and `LOCALAPPDATA`; it defaults
  /// to the current process environment.
  ToolInstaller({
    required this._runner,
    required this._reporter,
    required this._prompter,
    required this.os,
    required String homeDir,
    this.dryRun = false,
    Map<String, String>? environment,
  }) : _home = homeDir,
       _env = environment ?? Platform.environment;

  /// The tool names [ensure] accepts.
  static const tools = ['git', 'gh', 'claude', 'secret-tool'];

  /// Time limit for a `--version` style check.
  static const checkTimeout = Duration(seconds: 30);

  /// Time limit for one installer run.
  static const installTimeout = Duration(minutes: 10);

  /// Hint when Claude Code was installed but still doesn't start.
  static const claudeSetupHint =
      'Open a new terminal and run "claude --version". If it still fails, see '
      'https://docs.claude.com/en/docs/claude-code/setup.';

  static const _names = {'git': 'Git', 'gh': 'GitHub CLI', 'claude': 'Claude Code', 'secret-tool': 'secret-tool'};
  static const _wingetIds = {'git': 'Git.Git', 'gh': 'GitHub.cli'};
  static const _appInstallerHint = 'Install "App Installer" from the Microsoft Store, then run this again.';
  static const _xcodeHint = 'Run "xcode-select --install", wait for it to finish, then run this again.';
  static const _ghSite = 'https://cli.github.com';
  static const _unixClaudeInstaller =
      "set -o pipefail; curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 --retry 3 "
      'https://claude.ai/install.sh | bash';
  static const _windowsClaudeInstaller = 'irm https://claude.ai/install.ps1 -TimeoutSec 300 | iex';

  /// The operating system tools are installed on.
  final HostOs os;

  /// When true, installers and sudo are never started.
  final bool dryRun;

  final CommandRunner _runner;
  final Reporter _reporter;
  final Prompter _prompter;
  final String _home;
  final Map<String, String> _env;

  /// Full paths of tools found outside PATH, by tool name.
  final Map<String, String> _resolved = {};

  // Cached facts about the machine, so several tools don't repeat the checks.
  bool _pmChecked = false;
  String? _pm;
  bool? _root;
  bool _aptUpdated = false;

  /// The command to run [tool] with after [ensure]: a full path when it was
  /// found outside PATH (for example right after winget installed it, while
  /// this process still has the old PATH, or `~/.local/bin/claude`),
  /// otherwise the plain tool name.
  String commandFor(String tool) => _resolved[tool] ?? tool;

  /// Checks [tool] ('git', 'gh', 'claude' or 'secret-tool') and installs or
  /// repairs it as [need] requires. Throws [ArgumentError] for any other name.
  Future<ToolOutcome> ensure(String tool, ToolNeed need) async {
    final name = _names[tool];
    if (name == null) throw ArgumentError.value(tool, 'tool', 'must be one of ${tools.join(', ')}');
    if (need == ToolNeed.skip) return const ToolOutcome('skipped');
    // Only Linux keeps Gita's tokens through secret-tool; Windows and macOS
    // have their own credential stores.
    if (tool == 'secret-tool' && os != HostOs.linux) return const ToolOutcome('not needed');

    final state = await _find(tool);
    if (state == _State.works) {
      _reporter.note('$name is installed.');
      return const ToolOutcome('already installed');
    }
    final broken = state == _State.broken;
    if (broken) _reporter.warn("$name is installed but doesn't run. Reinstalling it.");

    final optional = need == ToolNeed.optional;
    final attempt = await _install(tool, name, broken);
    switch (attempt) {
      case _DryRun():
        return const ToolOutcome('dry run');
      case _Unavailable(:final problem, :final hint):
        return _notInstalled(optional, problem, hint);
      case _Ran(:final exitCode, :final hint):
        if (await _find(tool) == _State.works) {
          _reporter.note('$name is installed.');
          return ToolOutcome(broken ? 'reinstalled' : 'installed');
        }
        final problem = exitCode == 0
            ? "$name was installed but doesn't run."
            : 'Installing $name failed (exit code $exitCode).';
        return _notInstalled(optional, problem, hint);
    }
  }

  ToolOutcome _notInstalled(bool optional, String problem, String hint) {
    if (optional) {
      _reporter.warn('$problem $hint');
      return ToolOutcome('not installed (optional)', hint: hint);
    }
    _reporter.warn(problem);
    return ToolOutcome('failed', failed: true, hint: hint);
  }

  // ------------------------------------------------------------ finding

  Future<CommandResult> _check(String command) =>
      _runner.run(command, const ['--version'], io: CommandIo.capture, timeout: checkTimeout);

  /// Whether [tool] runs, from PATH or from a known install location.
  Future<_State> _find(String tool) async {
    final r = await _check(tool);
    // secret-tool has no --version: it prints its usage and exits non-zero.
    // Like the setup script, being found is enough.
    final exists = r.exitCode != CommandResult.notFound && r.exitCode != CommandResult.timedOut;
    if (r.ok || (tool == 'secret-tool' && exists)) {
      _resolved.remove(tool);
      return _State.works;
    }
    // A fresh install is often not on this process's PATH yet.
    for (final path in _candidates(tool)) {
      if ((await _check(path)).ok) {
        _resolved[tool] = path;
        return _State.works;
      }
    }
    return r.exitCode == CommandResult.notFound ? _State.missing : _State.broken;
  }

  /// Known install locations of [tool] outside PATH.
  List<String> _candidates(String tool) {
    if (tool == 'claude') {
      return [os == HostOs.windows ? '$_home\\.local\\bin\\claude.exe' : '$_home/.local/bin/claude'];
    }
    switch (os) {
      case HostOs.windows:
        final programFiles = _envVar('ProgramFiles') ?? r'C:\Program Files';
        final localAppData = _envVar('LOCALAPPDATA') ?? '$_home\\AppData\\Local';
        final links = '$localAppData\\Microsoft\\WinGet\\Links';
        return switch (tool) {
          'git' => [
            '$programFiles\\Git\\cmd\\git.exe',
            '$localAppData\\Programs\\Git\\cmd\\git.exe',
            '$links\\git.exe',
          ],
          'gh' => [
            '$programFiles\\GitHub CLI\\gh.exe',
            '$localAppData\\Programs\\GitHub CLI\\gh.exe',
            '$links\\gh.exe',
          ],
          _ => const [],
        };
      case HostOs.macos:
        // Homebrew's folders on Apple silicon and Intel Macs.
        return tool == 'gh' ? const ['/opt/homebrew/bin/gh', '/usr/local/bin/gh'] : const [];
      case HostOs.linux:
        return const [];
    }
  }

  /// Environment lookup that ignores case, as Windows does.
  String? _envVar(String name) {
    final exact = _env[name];
    if (exact != null && exact.isNotEmpty) return exact;
    for (final e in _env.entries) {
      if (e.key.toUpperCase() == name.toUpperCase() && e.value.isNotEmpty) return e.value;
    }
    return null;
  }

  // ------------------------------------------------------------ installing

  Future<_Attempt> _install(String tool, String name, bool broken) async {
    if (tool == 'claude') return _installClaude(name);
    switch (os) {
      case HostOs.windows:
        return _winget(tool, name, broken);
      case HostOs.macos:
        // /usr/bin/git exists even without the developer tools and only works
        // with them; installing them opens a system dialog, so the person
        // starts it themselves.
        if (tool == 'git') return const _Unavailable('Git is missing or not working.', _xcodeHint);
        return _brew(name, broken);
      case HostOs.linux:
        return _linuxPackage(tool, name, broken);
    }
  }

  Future<_Attempt> _winget(String tool, String name, bool broken) async {
    if (!(await _check('winget')).ok) {
      return _Unavailable("$name is missing and winget isn't available.", _appInstallerHint);
    }
    final args = [
      'install',
      '--id',
      _wingetIds[tool]!,
      '-e',
      '--source',
      'winget',
      '--accept-package-agreements',
      '--accept-source-agreements',
      '--silent',
      // Without --force winget skips a package it thinks is installed, even
      // when the program no longer runs.
      if (broken) '--force',
    ];
    _reporter.say('Installing $name');
    if (dryRun) {
      _reporter.note('[dry run] would install $name with "winget ${args.join(' ')}"');
      return const _DryRun();
    }
    final r = await _runner.run('winget', args, io: CommandIo.show, timeout: installTimeout);
    final yourself = tool == 'gh' ? 'get it from $_ghSite' : 'install it yourself';
    return _Ran(r.exitCode, 'The messages above say why. Open a new terminal and run this again, or $yourself.');
  }

  Future<_Attempt> _brew(String name, bool broken) async {
    final brew = await _findBrew();
    if (brew == null) {
      return _Unavailable(
        "$name is missing and Homebrew isn't available.",
        'Install Homebrew from https://brew.sh or get $name from $_ghSite, then run this again.',
      );
    }
    final args = [broken ? 'reinstall' : 'install', 'gh'];
    _reporter.say('Installing $name');
    if (dryRun) {
      _reporter.note('[dry run] would install $name with "brew ${args.join(' ')}"');
      return const _DryRun();
    }
    final r = await _runner.run(brew, args, io: CommandIo.show, timeout: installTimeout);
    return _Ran(
      r.exitCode,
      'The messages above say why. Run "brew ${args.join(' ')}" yourself or get it from $_ghSite.',
    );
  }

  Future<String?> _findBrew() async {
    for (final brew in const ['brew', '/opt/homebrew/bin/brew', '/usr/local/bin/brew']) {
      if ((await _check(brew)).ok) return brew;
    }
    return null;
  }

  Future<_Attempt> _installClaude(String name) async {
    final String exe;
    final List<String> args;
    if (os == HostOs.windows) {
      exe = 'powershell';
      args = const ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', _windowsClaudeInstaller];
    } else {
      exe = 'bash';
      args = const ['-c', _unixClaudeInstaller];
    }
    _reporter.say('Installing $name');
    if (dryRun) {
      _reporter.note('[dry run] would install $name with the official installer from claude.ai');
      return const _DryRun();
    }
    // The Unix installer is fetched with curl, which minimal Linux systems
    // lack; macOS always has it.
    if (os == HostOs.linux && !(await _check('curl')).ok) {
      final curl = await _linuxPackage('curl', 'curl', false);
      if (curl is _Unavailable) return _Unavailable('$name needs curl. ${curl.problem}', curl.hint);
      if (!(await _check('curl')).ok) {
        return _Unavailable("$name needs curl, and curl couldn't be installed.", (curl as _Ran).hint);
      }
    }
    final r = await _runner.run(
      exe,
      args,
      io: CommandIo.show,
      timeout: installTimeout,
      environment: os == HostOs.windows ? windowsPowerShellEnvironment : const {},
    );
    return _Ran(
      r.exitCode,
      r.ok ? claudeSetupHint : 'Check your internet connection and the messages above, then run this again.',
    );
  }

  // ------------------------------------------------------------ Linux packages

  Future<_Attempt> _linuxPackage(String tool, String name, bool reinstall) async {
    final pm = await _packageManager();
    if (pm == null) {
      return _Unavailable(
        '$name is missing and no supported package manager (apt-get, dnf or pacman) was found.',
        'Install $name with your package manager, then run this again.',
      );
    }
    final pkg = _packageName(pm, tool);
    final commands = <List<String>>[
      if (pm == 'apt-get' && !_aptUpdated) const ['apt-get', 'update', '-qq'],
      switch (pm) {
        'apt-get' => ['apt-get', 'install', '-y', '-qq', if (reinstall) '--reinstall', pkg],
        'dnf' => ['dnf', if (reinstall) 'reinstall' else 'install', '-y', pkg],
        // Without --needed pacman installs the package again.
        _ => ['pacman', '-S', if (!reinstall) '--needed', '--noconfirm', pkg],
      },
    ];
    final root = await _isRoot();
    List<String> admin(List<String> c) => root ? c : ['sudo', ...c];
    final shown = commands.map((c) => admin(c).join(' ')).join(' && ');

    _reporter.say(root ? 'Installing $name' : 'Installing $name (may ask for your password)');
    if (dryRun) {
      _reporter.note('[dry run] would install $pkg with "$shown"');
      return const _DryRun();
    }
    final afterHint = tool == 'secret-tool'
        ? 'Install $pkg with $pm yourself, then run this again.'
        : 'Run "$tool --version" to see why.';

    if (!root && !_prompter.interactive) {
      // No terminal for sudo to ask for a password: try without one, and if
      // sudo needs it, tell the person exactly what to run.
      for (final c in commands) {
        final r = await _runner.run('sudo', ['-n', ...c], io: CommandIo.capture, timeout: installTimeout);
        if (!r.ok) {
          return _Unavailable(
            "Couldn't install $pkg: there is no terminal for sudo to ask for your password, or the install failed.",
            'Run "$shown" in a terminal, then run this again.',
          );
        }
        if (c[0] == 'apt-get' && c[1] == 'update') _aptUpdated = true;
      }
      return _Ran(0, afterHint);
    }

    if (!root) _reporter.note('Running: $shown');
    for (final c in commands) {
      final full = admin(c);
      final r = await _runner.run(
        full.first,
        full.sublist(1),
        // sudo asks for the password on the terminal itself.
        io: root ? CommandIo.show : CommandIo.terminal,
        timeout: installTimeout,
      );
      if (!r.ok) return _Ran(r.exitCode, 'The messages above say why. Run "$shown" yourself, then run this again.');
      if (c[0] == 'apt-get' && c[1] == 'update') _aptUpdated = true;
    }
    return _Ran(0, afterHint);
  }

  /// The first package manager found: apt-get, dnf or pacman.
  Future<String?> _packageManager() async {
    if (_pmChecked) return _pm;
    for (final pm in const ['apt-get', 'dnf', 'pacman']) {
      if ((await _check(pm)).exitCode != CommandResult.notFound) {
        _pm = pm;
        break;
      }
    }
    _pmChecked = true;
    return _pm;
  }

  Future<bool> _isRoot() async {
    final cached = _root;
    if (cached != null) return cached;
    final r = await _runner.run('id', const ['-u'], io: CommandIo.capture, timeout: checkTimeout);
    return _root = r.ok && r.stdout.trim() == '0';
  }

  /// The package that provides [tool] for package manager [pm].
  static String _packageName(String pm, String tool) => switch ((pm, tool)) {
    ('apt-get', 'secret-tool') => 'libsecret-tools',
    ('dnf' || 'pacman', 'secret-tool') => 'libsecret',
    ('pacman', 'gh') => 'github-cli',
    _ => tool,
  };
}

enum _State { works, broken, missing }

/// What an install step did.
sealed class _Attempt {
  const _Attempt();
}

/// Nothing was run because of the dry run.
class _DryRun extends _Attempt {
  const _DryRun();
}

/// There was no way to install the tool here.
class _Unavailable extends _Attempt {
  const _Unavailable(this.problem, this.hint);
  final String problem;
  final String hint;
}

/// An installer ran; [hint] applies if the tool still doesn't work.
class _Ran extends _Attempt {
  const _Ran(this.exitCode, this.hint);
  final int exitCode;
  final String hint;
}
