import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/onboarding/github_cleanup.dart';
import 'package:gita/core/onboarding/onboarding_file.dart';
import 'package:gita/core/onboarding/system.dart';

/// Real git against a throwaway home and global config; gh, cmdkey and reg
/// answer from scripts so nothing on this machine is read or changed.
class _TestRunner implements CommandRunner {
  _TestRunner(this.home);

  final String home;
  final calls = <List<String>>[];
  final envs = <Map<String, String?>>[];
  CommandResult Function(List<String> args, CommandIo io) gh = (_, _) => const CommandResult(1);
  CommandResult Function(List<String> args) cmdkey = (_) => const CommandResult(0);
  CommandResult Function(List<String> args) reg = (_) => const CommandResult(1);

  static const _real = SystemCommandRunner();

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
    calls.add([executable, ...arguments]);
    envs.add(environment);
    switch (executable) {
      case 'gh':
        return gh(arguments, io);
      case 'cmdkey':
        return cmdkey(arguments);
      case 'reg':
        return reg(arguments);
      case 'git':
        return _real.run(
          'git',
          arguments,
          io: io,
          environment: {...environment, ...gitEnv(home)},
          workingDirectory: workingDirectory,
          stdinText: stdinText,
          timeout: timeout,
        );
      default:
        return _real.run(executable, arguments, environment: environment, workingDirectory: workingDirectory);
    }
  }

  static Map<String, String?> gitEnv(String home) => {
    'GIT_CONFIG_GLOBAL': '$home${Platform.pathSeparator}.gitconfig',
    'GIT_CONFIG_NOSYSTEM': '1',
    'HOME': home,
    'USERPROFILE': home,
    'XDG_CONFIG_HOME': '$home${Platform.pathSeparator}.config',
  };

  List<List<String>> callsTo(String exe) => [
    for (final c in calls)
      if (c.first == exe) c,
  ];
}

class _Reporter implements Reporter {
  final lines = <String>[];
  @override
  void say(String text) => lines.add('say: $text');
  @override
  void note(String text) => lines.add('note: $text');
  @override
  void warn(String text) => lines.add('warn: $text');
  String get all => lines.join('\n');
}

class _Prompter implements Prompter {
  _Prompter({required this.interactive, this.answer = true});
  @override
  final bool interactive;
  final bool answer;
  final asked = <String>[];
  @override
  Future<String> ask(String question, {String defaultValue = ''}) async => defaultValue;
  @override
  Future<bool> confirm(String question, {required bool defaultYes}) async {
    asked.add(question);
    return answer;
  }
}

const _secrets = ['SECRETVALUE', 'FAKEVALUE', 'SECRETB64'];

void main() {
  late Directory tmp;
  late String home;
  late _TestRunner runner;
  late _Reporter reporter;

  String file(String name) => '$home${Platform.pathSeparator}$name';

  Future<void> git(List<String> args) async {
    final r = await runner.run('git', args);
    expect(r.exitCode, 0, reason: 'git ${args.first} failed: ${r.stderr}');
  }

  Future<String> globalConfig() async => (await const SystemCommandRunner().run('git', [
    'config',
    '--global',
    '--list',
  ], environment: _TestRunner.gitEnv(home))).stdout;

  Future<String> fill(String host) async => (await const SystemCommandRunner().run(
    'git',
    ['credential', 'fill'],
    environment: {..._TestRunner.gitEnv(home), 'GIT_TERMINAL_PROMPT': '0'},
    workingDirectory: home,
    stdinText: 'protocol=https\nhost=$host\n\n',
  )).stdout;

  GitHubCleanup cleanup({bool isWindows = false, Prompter? prompter, Map<String, String> env = const {}}) =>
      GitHubCleanup(
        runner: runner,
        reporter: reporter,
        prompter: prompter ?? _Prompter(interactive: false),
        isWindows: isWindows,
        homeDir: home,
        now: () => DateTime(2026, 11, 9, 8, 5, 3),
        environment: env,
      );

  void expectNoSecrets(GitHubCleanup c, [CleanupFindings? f]) {
    for (final s in _secrets) {
      expect(reporter.all, isNot(contains(s)));
      for (final i in f?.items ?? const <CleanupItem>[]) {
        expect(i.description, isNot(contains(s)));
      }
      for (final r in f?.reportOnly ?? const <String>[]) {
        expect(r, isNot(contains(s)));
      }
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gita-cleanup-');
    home = tmp.resolveSymbolicLinksSync();
    runner = _TestRunner(home);
    reporter = _Reporter();
    File(file('.gitconfig')).writeAsStringSync('');
    File(
      file('.git-credentials'),
    ).writeAsStringSync('https://olduser:FAKEVALUE@github.com\nhttps://someone:FAKEVALUE@example.com\n');
    await git(['config', '--global', 'credential.helper', 'store']);
    await git(['config', '--global', 'url.https://x-token:SECRETVALUE@github.com/.insteadOf', 'https://github.com/']);
    await git(['config', '--global', 'http.https://github.com/.extraheader', 'AUTHORIZATION: basic SECRETB64']);
    await git(['config', '--global', 'url.git@gitlab.com:.insteadOf', 'https://gitlab.com/']);
    runner.calls.clear();
    runner.envs.clear();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('find lists exactly the github.com items, redacted', () async {
    final c = cleanup();
    final f = await c.find();
    expect(f.items.map((i) => i.kind), [CleanupKind.savedLogin, CleanupKind.gitConfig, CleanupKind.gitConfig]);
    expect(f.items[0].description, contains('Saved github.com logins in: store'));
    expect(f.items[1].description, contains('url.https://***@github.com/.insteadof = https://github.com/'));
    expect(f.items[1].arg, contains('SECRETVALUE'), reason: 'removal needs the real key');
    expect(f.items[2].description, contains('http.https://github.com/.extraheader'));
    expect(f.items.any((i) => i.description.contains('gitlab')), isFalse);
    expect(f.reportOnly, isEmpty);
    expectNoSecrets(c, f);
  });

  test('dry run lists but changes nothing', () async {
    final before = await globalConfig();
    final c = cleanup();
    final o = await c.run(CleanupMode.yes, dryRun: true);
    expect(o.summary, 'dry run');
    expect(await globalConfig(), before);
    expect(await fill('github.com'), contains('password='));
    expect(reporter.all, contains('Found these. They can make git or gh use an old GitHub account'));
    expect(Directory(home).listSync().where((e) => e.path.contains('.backup-')), isEmpty);
    expectNoSecrets(c);
  });

  test('yes removes github.com items, keeps others, backs up', () async {
    final c = cleanup();
    final o = await c.run(CleanupMode.yes);
    expect(o.summary, 'cleaned (3)');
    expect(o.failed, isFalse);
    expect(o.ghLoggedOut, isFalse);
    final cfg = await globalConfig();
    expect(cfg, isNot(contains('github.com')));
    expect(cfg, contains('url.git@gitlab.com:.insteadof=https://gitlab.com/'));
    expect(cfg, contains('credential.helper=store'));
    expect(await fill('github.com'), isNot(contains('password=')));
    expect(await fill('example.com'), contains('password='));
    final backup = File(file('.gitconfig.backup-20261109-080503'));
    expect(backup.existsSync(), isTrue);
    expect(backup.readAsStringSync(), contains('SECRETVALUE'));
    if (!Platform.isWindows) {
      expect(backup.statSync().mode & 0x1ff, 0x180); // 0600
    }
    expect(reporter.all, contains('Removed 3 of 3.'));
    expectNoSecrets(c);
  });

  test('backup name never overwrites an earlier backup', () async {
    File(file('.gitconfig.backup-20261109-080503')).writeAsStringSync('earlier');
    File(file('.gitconfig.backup-20261109-080503-2')).writeAsStringSync('earlier');
    await cleanup().run(CleanupMode.yes);
    expect(File(file('.gitconfig.backup-20261109-080503')).readAsStringSync(), 'earlier');
    expect(File(file('.gitconfig.backup-20261109-080503-3')).existsSync(), isTrue);
  });

  test('ask without a terminal keeps everything', () async {
    final before = await globalConfig();
    final o = await cleanup().run(CleanupMode.ask);
    expect(o.summary, 'kept (3 found; no terminal to ask)');
    expect(await globalConfig(), before);
    expect(await fill('github.com'), contains('password='));
  });

  test('ask and answer no keeps everything', () async {
    final before = await globalConfig();
    final p = _Prompter(interactive: true, answer: false);
    final o = await cleanup(prompter: p).run(CleanupMode.ask);
    expect(p.asked, ['Remove these?']);
    expect(o.summary, 'kept (3 found)');
    expect(await globalConfig(), before);
  });

  test('ask and answer yes cleans', () async {
    final o = await cleanup(prompter: _Prompter(interactive: true)).run(CleanupMode.ask);
    expect(o.summary, 'cleaned (3)');
  });

  test('skip does not look', () async {
    final o = await cleanup().run(CleanupMode.skip);
    expect(o.summary, 'skipped');
    expect(runner.calls, isEmpty);
  });

  test('second run finds nothing to clean', () async {
    expect((await cleanup().run(CleanupMode.yes)).summary, 'cleaned (3)');
    expect((await cleanup().run(CleanupMode.yes)).summary, 'nothing to clean');
  });

  test('a global Authorization header and a github.com helper are found', () async {
    await git(['config', '--global', 'http.extraheader', 'Authorization: bearer SECRETVALUE']);
    await git(['config', '--global', 'credential.https://github.com.helper', '!echo password=SECRETVALUE']);
    final c = cleanup();
    final f = await c.find();
    final texts = f.items.map((i) => i.description).join('\n');
    expect(texts, contains('git setting http.extraheader (a sign-in header'));
    expect(texts, contains('credential.https://github.com.helper = (a custom command)'));
    expectNoSecrets(c, f);
    expect((await c.run(CleanupMode.yes)).summary, 'cleaned (5)');
    expect(await globalConfig(), isNot(contains('extraheader')));
  });

  test('gh logins are parsed and signed out one by one without env tokens', () async {
    runner.gh = (args, io) {
      if (args.take(2).join(' ') == 'auth status') {
        return const CommandResult(
          0,
          stdout:
              'github.com\n  2713 Logged in to github.com account old-user (keyring)\n'
              '  2713 Logged in to github.com account second (keyring)\n',
        );
      }
      return const CommandResult(0);
    };
    final o = await cleanup().run(CleanupMode.yes);
    expect(o.summary, 'cleaned (5)');
    expect(o.ghLoggedOut, isTrue);
    final logouts = runner.callsTo('gh').where((c) => c[2] == 'logout').toList();
    expect(logouts, [
      ['gh', 'auth', 'logout', '--hostname', 'github.com', '--user', 'old-user'],
      ['gh', 'auth', 'logout', '--hostname', 'github.com', '--user', 'second'],
    ]);
    for (var i = 0; i < runner.calls.length; i++) {
      if (runner.calls[i].first == 'gh') {
        expect(runner.envs[i], containsPair('GH_TOKEN', null));
        expect(runner.envs[i], containsPair('GITHUB_TOKEN', null));
      }
    }
  });

  test('older gh "as" form on stderr; failed logout without terminal is reported', () async {
    runner.gh = (args, io) => args[1] == 'status'
        ? const CommandResult(0, stderr: 'github.com\n  2713 Logged in to github.com as olduser (oauth_token)\n')
        : const CommandResult(1);
    final o = await cleanup().run(CleanupMode.yes);
    expect(o.summary, 'cleaned 3 of 4 (some failed)');
    expect(o.failed, isTrue);
    expect(o.ghLoggedOut, isFalse);
    expect(runner.callsTo('gh').where((c) => c[2] == 'logout'), hasLength(1));
    expect(reporter.all, contains("Couldn't sign GitHub CLI out of @olduser."));
  });

  test('failed gh logout falls back to the terminal when there is one', () async {
    runner.gh = (args, io) {
      if (args[1] == 'status') return const CommandResult(0, stdout: 'Logged in to github.com account olduser');
      return io == CommandIo.terminal ? const CommandResult(0) : const CommandResult(1);
    };
    final o = await cleanup(prompter: _Prompter(interactive: true)).run(CleanupMode.yes);
    expect(o.summary, 'cleaned (4)');
    expect(o.ghLoggedOut, isTrue);
  });

  test('Windows Credential Manager entries matched by name, any language', () async {
    var listing =
        'Aktuell gespeicherte Anmeldeinformationen:\r\n\r\n'
        '    Ziel: LegacyGeneric:target=git:https://github.com\r\n'
        '    Typ: Generisch\r\n'
        '    Benutzer: olduser\r\n\r\n'
        '    Ziel: LegacyGeneric:target=git:https://olduser@github.com\r\n'
        '    Ziel: git:https://other@github.com/some/path\r\n'
        '    Ziel: LegacyGeneric:target=git:https://github.com.example.net\r\n'
        '    Ziel: LegacyGeneric:target=git:https://gitlab.com\r\n'
        '    Ziel: LegacyGeneric:target=git:https://github.com\r\n';
    final deleted = <String>[];
    runner.cmdkey = (args) {
      if (args.first == '/list') return CommandResult(0, stdout: listing);
      final name = args.first.substring('/delete:'.length);
      if (name.startsWith('LegacyGeneric:target=git:https://other@')) return const CommandResult(1);
      deleted.add(name);
      if (name == 'git:https://other@github.com/some/path') {
        listing = listing.replaceAll('    Ziel: git:https://other@github.com/some/path\r\n', '');
      }
      return const CommandResult(0);
    };
    final c = cleanup(isWindows: true);
    final f = await c.find();
    final names = [
      for (final i in f.items)
        if (i.kind == CleanupKind.credentialManager) i.arg,
    ];
    expect(names, [
      'git:https://github.com',
      'git:https://olduser@github.com',
      'git:https://other@github.com/some/path',
    ]);
    final o = await c.run(CleanupMode.yes);
    expect(o.summary, 'cleaned (6)');
    expect(deleted, [
      'LegacyGeneric:target=git:https://github.com',
      'LegacyGeneric:target=git:https://olduser@github.com',
      'git:https://other@github.com/some/path',
    ]);
  });

  test('Windows Credential Manager entry already gone counts as done', () async {
    runner.cmdkey = (args) => args.first == '/list'
        ? CommandResult(0, stdout: runner.callsTo('cmdkey').length == 1 ? 'Target: git:https://github.com\n' : '')
        : const CommandResult(1);
    final o = await cleanup(isWindows: true).run(CleanupMode.yes);
    expect(o.summary, 'cleaned (4)');
  });

  test('Windows token variables: user ones removed, machine ones reported', () async {
    runner.reg = (args) {
      if (args.first == 'query') {
        final user = args[1] == r'HKCU\Environment';
        return CommandResult(user == (args[3] == 'GH_TOKEN') ? 0 : 1, stdout: 'REG_SZ SECRETVALUE');
      }
      return const CommandResult(0);
    };
    final c = cleanup(isWindows: true, env: {'GH_TOKEN': 'SECRETVALUE', 'GITHUB_TOKEN': 'SECRETVALUE'});
    final f = await c.find();
    expect(f.items.where((i) => i.kind == CleanupKind.userTokenVariable).map((i) => i.arg), ['GH_TOKEN']);
    expect(f.reportOnly, hasLength(2));
    expect(f.reportOnly[0], startsWith('GITHUB_TOKEN is set for all users'));
    expect(f.reportOnly[1], startsWith('GITHUB_TOKEN is set in this terminal'));
    final o = await c.run(CleanupMode.yes);
    expect(o.summary, 'cleaned (4)');
    expect(runner.callsTo('reg').where((c) => c[1] == 'delete'), [
      ['reg', 'delete', r'HKCU\Environment', '/v', 'GH_TOKEN', '/f'],
    ]);
    expectNoSecrets(c, f);
  });

  test('Windows-only checks are off when isWindows is false', () async {
    await cleanup().find();
    expect(runner.callsTo('cmdkey'), isEmpty);
    expect(runner.callsTo('reg'), isEmpty);
  });

  test('report-only: process token, shell profile and ssh Host entry', () async {
    File(file('.zshrc')).writeAsStringSync('export GITHUB_TOKEN=SECRETVALUE\n');
    Directory(file('.ssh')).createSync();
    File(file('.ssh${Platform.pathSeparator}config')).writeAsStringSync('Host github.com\n  User git\n');
    final c = cleanup(env: {'GH_TOKEN': 'SECRETVALUE'});
    final o = await c.run(CleanupMode.ask);
    expect(o.summary, 'kept (3 found; no terminal to ask)');
    expect(reporter.all, contains('warn: GH_TOKEN is set, probably in your shell profile.'));
    expect(reporter.all, contains('warn: GITHUB_TOKEN is set in ~/.zshrc.'));
    expect(reporter.all, contains('has a "Host github.com" entry'));
    expect(reporter.all, isNot(contains('User git')));
    expectNoSecrets(c);
  });

  test('report-only lines are shown even when nothing can be removed', () async {
    await git(['config', '--global', '--unset-all', 'credential.helper']);
    await git(['config', '--global', '--unset-all', 'url.https://x-token:SECRETVALUE@github.com/.insteadOf']);
    await git(['config', '--global', '--unset-all', 'http.https://github.com/.extraheader']);
    final o = await cleanup(env: {'GH_TOKEN': 'SECRETVALUE'}).run(CleanupMode.yes);
    expect(o.summary, 'nothing to clean');
    expect(reporter.all, contains('warn: GH_TOKEN is set'));
  });

  test('redact hides tokens in addresses', () {
    expect(
      GitHubCleanup.redact('https://u:t@github.com/x https://github.com'),
      'https://***@github.com/x https://github.com',
    );
  });
}
