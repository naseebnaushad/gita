import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/onboarding/onboarding_file.dart';
import 'package:gita/core/onboarding/system.dart';
import 'package:gita/core/onboarding/tools.dart';

/// One recorded program run.
class Call {
  Call(this.executable, this.arguments, this.io, this.timeout, [this.environment = const {}]);
  final String executable;
  final List<String> arguments;
  final CommandIo io;
  final Duration timeout;
  final Map<String, String?> environment;

  String get line => [executable, ...arguments].join(' ');
}

/// Returns scripted results keyed by the full command line. Each key holds a
/// queue: results are used in order and the last one repeats. Anything not
/// scripted is "not found".
class FakeRunner implements CommandRunner {
  final calls = <Call>[];
  final _script = <String, List<CommandResult>>{};

  void on(String line, List<int> exitCodes, {String stdout = ''}) =>
      _script[line] = [for (final c in exitCodes) CommandResult(c, stdout: stdout)];

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
    final call = Call(executable, List.of(arguments), io, timeout, Map.of(environment));
    calls.add(call);
    final queue = _script[call.line];
    if (queue == null || queue.isEmpty) return const CommandResult(CommandResult.notFound);
    return queue.length > 1 ? queue.removeAt(0) : queue.first;
  }

  /// Calls that are not `--version` checks or `id -u`.
  List<Call> get actions =>
      calls.where((c) => !(c.arguments.length == 1 && c.arguments[0] == '--version')).toList()
        ..removeWhere((c) => c.executable == 'id');
}

class FakeReporter implements Reporter {
  final lines = <String>[];
  @override
  void say(String text) => lines.add('say: $text');
  @override
  void note(String text) => lines.add('note: $text');
  @override
  void warn(String text) => lines.add('warn: $text');
}

class FakePrompter implements Prompter {
  FakePrompter({this.interactive = false});
  @override
  final bool interactive;
  @override
  Future<String> ask(String question, {String defaultValue = ''}) async => defaultValue;
  @override
  Future<bool> confirm(String question, {required bool defaultYes}) async => defaultYes;
}

const _winEnv = {'ProgramFiles': r'C:\Program Files', 'LOCALAPPDATA': r'C:\Users\dev\AppData\Local'};
const _wingetBase = [
  'install',
  '--id',
  'Git.Git',
  '-e',
  '--source',
  'winget',
  '--accept-package-agreements',
  '--accept-source-agreements',
  '--silent',
];

const _unixInstallerLine =
    "bash -c set -o pipefail; curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 600 "
    '--retry 3 https://claude.ai/install.sh | bash';

void main() {
  late FakeRunner runner;
  late FakeReporter reporter;

  setUp(() {
    runner = FakeRunner();
    reporter = FakeReporter();
  });

  ToolInstaller make(HostOs os, {bool interactive = false, bool dryRun = false}) => ToolInstaller(
    runner: runner,
    reporter: reporter,
    prompter: FakePrompter(interactive: interactive),
    os: os,
    homeDir: os == HostOs.windows ? r'C:\Users\dev' : '/home/dev',
    dryRun: dryRun,
    environment: _winEnv,
  );

  group('common', () {
    test('a working tool is reported as already installed and nothing is installed', () async {
      runner.on('git --version', [0]);
      for (final os in HostOs.values) {
        final out = await make(os).ensure('git', ToolNeed.required);
        expect(out.summary, 'already installed');
        expect(out.failed, isFalse);
      }
      expect(runner.actions, isEmpty);
    });

    test('skip runs nothing', () async {
      final out = await make(HostOs.linux).ensure('gh', ToolNeed.skip);
      expect(out.summary, 'skipped');
      expect(runner.calls, isEmpty);
    });

    test('secret-tool is not needed outside Linux', () async {
      expect((await make(HostOs.windows).ensure('secret-tool', ToolNeed.required)).summary, 'not needed');
      expect((await make(HostOs.macos).ensure('secret-tool', ToolNeed.required)).summary, 'not needed');
      expect(runner.calls, isEmpty);
    });

    test('an unknown tool name is rejected', () {
      expect(() => make(HostOs.linux).ensure('rm', ToolNeed.required), throwsArgumentError);
    });

    test('commandFor defaults to the tool name', () {
      expect(make(HostOs.linux).commandFor('gh'), 'gh');
    });

    test('checks use a short time limit and capture output', () async {
      runner.on('gh --version', [0]);
      await make(HostOs.linux).ensure('gh', ToolNeed.required);
      expect(runner.calls.single.io, CommandIo.capture);
      expect(runner.calls.single.timeout, lessThanOrEqualTo(const Duration(seconds: 30)));
    });
  });

  group('Windows', () {
    test('missing Git is installed with winget and found at its install path', () async {
      runner
        ..on('winget --version', [0])
        ..on('winget ${_wingetBase.join(' ')}', [0])
        ..on(r'C:\Program Files\Git\cmd\git.exe --version', [CommandResult.notFound, 0]);
      final installer = make(HostOs.windows);
      final out = await installer.ensure('git', ToolNeed.required);
      expect(out.summary, 'installed');
      final install = runner.actions.single;
      expect(install.executable, 'winget');
      expect(install.arguments, _wingetBase);
      expect(install.io, CommandIo.show);
      expect(install.timeout, lessThanOrEqualTo(const Duration(minutes: 10)));
      expect(installer.commandFor('git'), r'C:\Program Files\Git\cmd\git.exe');
    });

    test('broken GitHub CLI is reinstalled with --force', () async {
      runner
        ..on('gh --version', [1, 0])
        ..on('winget --version', [0])
        ..on('winget ${[..._wingetBase, '--force'].join(' ').replaceFirst('Git.Git', 'GitHub.cli')}', [0]);
      final installer = make(HostOs.windows);
      final out = await installer.ensure('gh', ToolNeed.required);
      expect(out.summary, 'reinstalled');
      expect(runner.actions.single.arguments, containsAllInOrder(['--id', 'GitHub.cli']));
      expect(runner.actions.single.arguments.last, '--force');
      expect(reporter.lines, contains(contains("doesn't run. Reinstalling")));
      expect(installer.commandFor('gh'), 'gh');
    });

    test('no winget: required fails with the App Installer hint', () async {
      final out = await make(HostOs.windows).ensure('git', ToolNeed.required);
      expect(out.failed, isTrue);
      expect(out.summary, 'failed');
      expect(out.hint, contains('"App Installer" from the Microsoft Store'));
      expect(runner.actions, isEmpty);
    });

    test('required tool still broken after install fails with a hint', () async {
      runner
        ..on('git --version', [1])
        ..on('winget --version', [0])
        ..on('winget ${[..._wingetBase, '--force'].join(' ')}', [0]);
      final out = await make(HostOs.windows).ensure('git', ToolNeed.required);
      expect(out.failed, isTrue);
      expect(out.hint, isNotEmpty);
    });

    test('Claude Code uses the official PowerShell installer', () async {
      runner.on(r'C:\Users\dev\.local\bin\claude.exe --version', [CommandResult.notFound, 0]);
      final installer = make(HostOs.windows);
      final out = await installer.ensure('claude', ToolNeed.required);
      expect(out.summary, 'installed');
      final install = runner.actions.single;
      expect(install.executable, 'powershell');
      expect(install.arguments, [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        'irm https://claude.ai/install.ps1 -TimeoutSec 300 | iex',
      ]);
      expect(install.io, CommandIo.show);
      // Started from PowerShell 7, Windows PowerShell must not inherit its
      // module path (the installer's Get-FileHash would be missing).
      expect(install.environment, {'PSModulePath': null});
      expect(installer.commandFor('claude'), r'C:\Users\dev\.local\bin\claude.exe');
    });
  });

  group('macOS', () {
    test('Git missing fails with the xcode-select hint and installs nothing', () async {
      runner.on('git --version', [1]);
      runner.on('brew --version', [0]);
      final out = await make(HostOs.macos).ensure('git', ToolNeed.required);
      expect(out.failed, isTrue);
      expect(out.hint, contains('xcode-select --install'));
      expect(runner.actions, isEmpty);
    });

    test('GitHub CLI is installed with Homebrew', () async {
      runner
        ..on('gh --version', [CommandResult.notFound, 0])
        ..on('brew --version', [0])
        ..on('brew install gh', [0]);
      final out = await make(HostOs.macos).ensure('gh', ToolNeed.required);
      expect(out.summary, 'installed');
      expect(runner.actions.single.line, 'brew install gh');
      expect(runner.actions.single.io, CommandIo.show);
    });

    test('broken GitHub CLI is reinstalled with Homebrew', () async {
      runner
        ..on('gh --version', [1, 0])
        ..on('brew --version', [0])
        ..on('brew reinstall gh', [0]);
      final out = await make(HostOs.macos).ensure('gh', ToolNeed.required);
      expect(out.summary, 'reinstalled');
      expect(runner.actions.single.line, 'brew reinstall gh');
    });

    test('optional GitHub CLI without Homebrew is not a failure', () async {
      final out = await make(HostOs.macos).ensure('gh', ToolNeed.optional);
      expect(out.failed, isFalse);
      expect(out.summary, 'not installed (optional)');
      expect(out.hint, contains('https://cli.github.com'));
      expect(runner.actions, isEmpty);
    });

    test('Claude Code found in ~/.local/bin after install', () async {
      runner.on('/home/dev/.local/bin/claude --version', [CommandResult.notFound, 0]);
      final installer = make(HostOs.macos);
      final out = await installer.ensure('claude', ToolNeed.required);
      expect(out.summary, 'installed');
      final install = runner.actions.single;
      expect(install.executable, 'bash');
      expect(install.arguments[0], '-c');
      expect(install.arguments[1], contains('https://claude.ai/install.sh | bash'));
      expect(install.arguments[1], startsWith('set -o pipefail;'));
      expect(install.timeout, lessThanOrEqualTo(const Duration(minutes: 10)));
      expect(installer.commandFor('claude'), '/home/dev/.local/bin/claude');
    });

    test('Claude Code still not running after install fails with the setup hint', () async {
      runner.on(_unixInstallerLine, [0]);
      final out = await make(HostOs.macos).ensure('claude', ToolNeed.required);
      expect(out.failed, isTrue);
      expect(out.hint, ToolInstaller.claudeSetupHint);
    });
  });

  group('Linux', () {
    test('apt: runs update first, then installs with sudo on the terminal', () async {
      runner
        ..on('apt-get --version', [0])
        ..on('git --version', [CommandResult.notFound, 0])
        ..on('sudo apt-get update -qq', [0])
        ..on('sudo apt-get install -y -qq git', [0]);
      final out = await make(HostOs.linux, interactive: true).ensure('git', ToolNeed.required);
      expect(out.summary, 'installed');
      expect(runner.actions.map((c) => c.line), ['sudo apt-get update -qq', 'sudo apt-get install -y -qq git']);
      expect(runner.actions.every((c) => c.io == CommandIo.terminal), isTrue);
      expect(reporter.lines, contains('note: Running: sudo apt-get update -qq && sudo apt-get install -y -qq git'));
    });

    test('apt: secret-tool comes from libsecret-tools and update runs only once', () async {
      runner
        ..on('apt-get --version', [0])
        ..on('sudo apt-get update -qq', [0])
        ..on('sudo apt-get install -y -qq libsecret-tools', [0])
        ..on('secret-tool --version', [CommandResult.notFound, 2])
        ..on('gh --version', [CommandResult.notFound, 0])
        ..on('sudo apt-get install -y -qq gh', [0]);
      final installer = make(HostOs.linux, interactive: true);
      expect((await installer.ensure('secret-tool', ToolNeed.required)).summary, 'installed');
      expect((await installer.ensure('gh', ToolNeed.required)).summary, 'installed');
      expect(runner.actions.map((c) => c.line), [
        'sudo apt-get update -qq',
        'sudo apt-get install -y -qq libsecret-tools',
        'sudo apt-get install -y -qq gh',
      ]);
    });

    test('apt: broken tool is reinstalled', () async {
      runner
        ..on('apt-get --version', [0])
        ..on('git --version', [1, 0])
        ..on('sudo apt-get update -qq', [0])
        ..on('sudo apt-get install -y -qq --reinstall git', [0]);
      final out = await make(HostOs.linux, interactive: true).ensure('git', ToolNeed.required);
      expect(out.summary, 'reinstalled');
    });

    test('dnf: package names and reinstall', () async {
      runner
        ..on('dnf --version', [0])
        ..on('sudo dnf install -y libsecret', [0])
        ..on('secret-tool --version', [CommandResult.notFound, 1])
        ..on('gh --version', [1, 0])
        ..on('sudo dnf reinstall -y gh', [0]);
      final installer = make(HostOs.linux, interactive: true);
      expect((await installer.ensure('secret-tool', ToolNeed.required)).summary, 'installed');
      expect((await installer.ensure('gh', ToolNeed.required)).summary, 'reinstalled');
      expect(runner.actions.map((c) => c.line), ['sudo dnf install -y libsecret', 'sudo dnf reinstall -y gh']);
    });

    test('pacman: github-cli and libsecret', () async {
      runner
        ..on('pacman --version', [0])
        ..on('sudo pacman -S --needed --noconfirm github-cli', [0])
        ..on('sudo pacman -S --needed --noconfirm libsecret', [0])
        ..on('gh --version', [CommandResult.notFound, 0])
        ..on('secret-tool --version', [CommandResult.notFound, 1]);
      final installer = make(HostOs.linux, interactive: true);
      expect((await installer.ensure('gh', ToolNeed.required)).summary, 'installed');
      expect((await installer.ensure('secret-tool', ToolNeed.required)).summary, 'installed');
      expect(runner.actions.map((c) => c.line), [
        'sudo pacman -S --needed --noconfirm github-cli',
        'sudo pacman -S --needed --noconfirm libsecret',
      ]);
    });

    test('root runs the package manager without sudo', () async {
      runner
        ..on('id -u', [0], stdout: '0\n')
        ..on('dnf --version', [0])
        ..on('dnf install -y git', [0])
        ..on('git --version', [CommandResult.notFound, 0]);
      final out = await make(HostOs.linux).ensure('git', ToolNeed.required);
      expect(out.summary, 'installed');
      expect(runner.actions.single.line, 'dnf install -y git');
      expect(runner.actions.single.io, CommandIo.show);
    });

    test('no terminal: tries sudo -n and, when it fails, gives the exact command', () async {
      runner
        ..on('apt-get --version', [0])
        ..on('sudo -n apt-get update -qq', [1]);
      final out = await make(HostOs.linux).ensure('git', ToolNeed.required);
      expect(out.failed, isTrue);
      expect(out.hint, contains('sudo apt-get update -qq && sudo apt-get install -y -qq git'));
      expect(runner.actions.single.line, 'sudo -n apt-get update -qq');
      expect(runner.actions.single.io, CommandIo.capture);
    });

    test('no terminal: optional tool is left out, not failed', () async {
      runner
        ..on('dnf --version', [0])
        ..on('sudo -n dnf install -y gh', [1]);
      final out = await make(HostOs.linux).ensure('gh', ToolNeed.optional);
      expect(out.failed, isFalse);
      expect(out.summary, 'not installed (optional)');
      expect(out.hint, contains('sudo dnf install -y gh'));
    });

    test('no terminal: sudo -n that works installs', () async {
      runner
        ..on('dnf --version', [0])
        ..on('sudo -n dnf install -y gh', [0])
        ..on('gh --version', [CommandResult.notFound, 0]);
      final out = await make(HostOs.linux).ensure('gh', ToolNeed.required);
      expect(out.summary, 'installed');
    });

    test('failed package install: required fails with the exact command', () async {
      runner
        ..on('pacman --version', [0])
        ..on('sudo pacman -S --needed --noconfirm git', [1]);
      final out = await make(HostOs.linux, interactive: true).ensure('git', ToolNeed.required);
      expect(out.failed, isTrue);
      expect(out.hint, contains('sudo pacman -S --needed --noconfirm git'));
    });

    test('no package manager: required fails, optional does not', () async {
      final installer = make(HostOs.linux, interactive: true);
      final git = await installer.ensure('git', ToolNeed.required);
      expect(git.failed, isTrue);
      expect(git.hint, contains('package manager'));
      final gh = await installer.ensure('gh', ToolNeed.optional);
      expect(gh.failed, isFalse);
      expect(runner.actions, isEmpty);
    });

    test('Claude Code installs curl first when it is missing', () async {
      runner
        ..on('apt-get --version', [0])
        ..on('curl --version', [CommandResult.notFound, 0])
        ..on('sudo apt-get update -qq', [0])
        ..on('sudo apt-get install -y -qq curl', [0])
        ..on('claude --version', [CommandResult.notFound, 0]);
      runner.on(_unixInstallerLine, [0]);
      final installer = make(HostOs.linux, interactive: true);
      final out = await installer.ensure('claude', ToolNeed.required);
      expect(out.summary, 'installed');
      expect(runner.actions.map((c) => c.executable), ['sudo', 'sudo', 'bash']);
      expect(installer.commandFor('claude'), 'claude');
    });
  });

  group('dry run', () {
    test('never starts an installer or sudo', () async {
      runner
        ..on('winget --version', [0])
        ..on('brew --version', [0])
        ..on('apt-get --version', [0]);
      for (final os in HostOs.values) {
        final installer = make(os, interactive: true, dryRun: true);
        for (final tool in ['gh', 'claude']) {
          expect((await installer.ensure(tool, ToolNeed.required)).summary, 'dry run', reason: '$os $tool');
        }
      }
      expect((await make(HostOs.linux, dryRun: true).ensure('secret-tool', ToolNeed.required)).summary, 'dry run');
      expect(runner.actions, isEmpty);
      expect(reporter.lines, contains(startsWith('note: [dry run] would install')));
    });

    test('a working tool is still reported as already installed', () async {
      runner.on('gh --version', [0]);
      expect((await make(HostOs.linux, dryRun: true).ensure('gh', ToolNeed.required)).summary, 'already installed');
    });
  });
}
