import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/onboarding/system.dart';
import 'package:gita/core/onboarding/tools.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:path/path.dart' as p;

/// Real git (isolated config), real Gita storage in a temp home, real clone
/// from a local "GitHub" repo; gh, Claude Code and Windows tools are fakes.
class _Runner implements CommandRunner {
  _Runner(this.env);
  final Map<String, String> env;
  final calls = <String>[];
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
    calls.add('$executable ${arguments.join(' ')}');
    final name = p.basenameWithoutExtension(executable);
    if (name == 'git' || name == 'bash' || name == 'powershell') {
      return _real.run(
        executable,
        arguments,
        io: io == CommandIo.terminal ? CommandIo.capture : io,
        environment: {...env, ...environment},
        workingDirectory: workingDirectory,
        stdinText: stdinText,
        timeout: timeout,
      );
    }
    if (arguments.length == 1 && arguments.single == '--version') {
      return CommandResult(0, stdout: '$name 1.0');
    }
    // gh auth status: not signed in; cmdkey/reg: nothing saved.
    return const CommandResult(1);
  }
}

class _Quiet implements Prompter {
  @override
  bool get interactive => false;
  @override
  Future<String> ask(String question, {String defaultValue = ''}) async => defaultValue;
  @override
  Future<bool> confirm(String question, {required bool defaultYes}) async => defaultYes;
}

void main() {
  late Directory home;
  late Directory tmp;
  late PlatformPaths paths;
  late GitService git;
  late Map<String, String> gitEnv;
  late StringBuffer out;
  late StringBuffer err;
  late TokenStore tokens;
  late _Runner runner;
  late String onboardingPath;
  late String seed;
  const url = 'https://github.com/example-lab/handbook.git';

  Future<void> sh(List<String> args, String dir) async {
    final r = await Process.run('git', args, workingDirectory: dir, environment: gitEnv);
    expect(r.exitCode, 0, reason: '${args.join(' ')}: ${r.stderr}');
  }

  Map<String, Object?> onboarding({String? unixScript, String? winScript}) => {
    'format': 1,
    'name': 'Example Co',
    'tools': {'git': 'required', 'gh': 'optional', 'claude': 'required'},
    'cleanup': 'ask',
    'accounts': [
      {'id': 'work', 'label': 'Example', 'emailDomain': 'example.com'},
      {'id': 'lab', 'label': 'Example Lab', 'emailDomain': 'example-lab.com'},
    ],
    'steps': [
      {'type': 'signIn', 'account': 'lab'},
      {'type': 'repo', 'account': 'lab', 'url': url, 'dir': '~/handbook'},
      {'type': 'companyFile', 'account': 'lab', 'repoDir': '~/handbook', 'path': 'gita/lab.json'},
      {
        'type': 'repoScript',
        'repoDir': '~/handbook',
        'windows': winScript ?? 'setup.ps1',
        'unix': unixScript ?? 'setup.sh',
      },
      {'type': 'signIn', 'account': 'work'},
      {'type': 'claudeCode'},
      {'type': 'doctor'},
    ],
  };

  Future<int> onboard(List<String> extra) => GitaCli(
    out: out,
    err: err,
    paths: paths,
    gitService: git,
    tokenStore: tokens,
    cwd: tmp.path,
    commandRunner: runner,
    prompter: _Quiet(),
    hostOs: Platform.isWindows ? HostOs.windows : (Platform.isMacOS ? HostOs.macos : HostOs.linux),
    runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
  ).run(['onboard', onboardingPath, ...extra]);

  const answers = ['--name', 'Dev Example', '--email', 'work=dev@example.com', '--email', 'lab=dev@example-lab.com'];

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_onb_home_');
    tmp = await Directory.systemTemp.createTemp('gita_onb_tmp_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    gitEnv = {'GIT_CONFIG_GLOBAL': paths.gitConfigPath, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0'};
    git = GitService(environmentOverride: gitEnv);
    out = StringBuffer();
    err = StringBuffer();
    tokens = TokenStore(keychain: InMemoryKeychainStore());
    runner = _Runner(gitEnv);

    // A local bare repo stands in for github.com.
    final bare = p.join(tmp.path, 'origin.git');
    seed = p.join(tmp.path, 'seed');
    await Process.run('git', ['init', '--bare', '-b', 'main', bare], environment: gitEnv);
    await Process.run('git', ['clone', bare, seed], environment: gitEnv);
    await sh(['config', 'user.email', 'seed@example.test'], seed);
    await sh(['config', 'user.name', 'Seed'], seed);
    Directory(p.join(seed, 'gita')).createSync();
    File(p.join(seed, 'gita', 'lab.json')).writeAsStringSync(
      jsonEncode({
        'name': 'Example Lab',
        'emailDomains': ['example-lab.com'],
        'github': {
          'owners': ['example-lab'],
        },
      }),
    );
    File(p.join(seed, 'setup.sh')).writeAsStringSync('echo ran > ran.txt\n');
    File(p.join(seed, 'setup.ps1')).writeAsStringSync("Set-Content -Path ran.txt -Value 'ran'\n");
    File(p.join(seed, 'fail.sh')).writeAsStringSync('echo broken >&2; exit 3\n');
    File(p.join(seed, 'fail.ps1')).writeAsStringSync('Write-Error broken; exit 3\n');
    await sh(['add', '.'], seed);
    await sh(['commit', '-qm', 'init'], seed);
    await sh(['push', '-q', 'origin', 'HEAD:main'], seed);
    File(paths.gitConfigPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('[url "${bare.replaceAll(r'\', '/')}"]\n\tinsteadOf = $url\n');

    onboardingPath = p.join(tmp.path, 'onboarding.json');
    File(onboardingPath).writeAsStringSync(jsonEncode(onboarding()));
  });

  tearDown(() async {
    for (final d in [home, tmp]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  test('a full run sets everything up, and a second run keeps it', () async {
    final code = await onboard([...answers, '--skip-sign-in']);
    final text = '$out$err';

    expect(code, ExitCodes.ok, reason: text);
    final profiles = await ProfileRepository(paths: paths).getAll();
    expect(profiles.map((x) => x.gitEmail).toSet(), {'dev@example.com', 'dev@example-lab.com'});
    expect(profiles.map((x) => x.label).toSet(), {'Example', 'Example Lab'});
    final repo = p.join(home.path, 'handbook');
    expect(File(p.join(repo, 'gita', 'lab.json')).existsSync(), isTrue, reason: text);
    expect(File(p.join(repo, 'ran.txt')).existsSync(), isTrue, reason: 'the setup script ran: $text');
    expect(text, contains('==> Summary'));
    expect(text, contains('downloaded'));
    expect(text, contains('imported'));
    expect(text, contains('skipped (--skip-sign-in)'));
    // Not running from ~/.gita/bin in a test, so Claude Code isn't connected; that is a warning, not a stop.
    expect(text, contains("couldn't connect (run gita mcp add-to-claude)"));
    expect(text, contains('Gita doctor'));
    expect(text, contains('kept (1 found; no terminal to ask)'), reason: 'the test insteadOf rule is found but kept');
    expect(text, isNot(contains('Setup stopped')));

    out.clear();
    final again = await onboard([...answers, '--skip-sign-in']);
    final text2 = '$out$err';
    expect(again, ExitCodes.ok, reason: text2);
    expect(text2, contains('Profile for dev@example.com already exists'));
    expect(text2, contains('updated'));
    expect((await ProfileRepository(paths: paths).getAll()).length, 2, reason: 'no duplicate profiles');
  });

  test('a dry run changes nothing', () async {
    final code = await onboard([...answers, '--dry-run']);

    expect(code, ExitCodes.ok, reason: '$out$err');
    expect(out.toString(), contains('Dry run finished. Nothing was changed.'));
    expect(await ProfileRepository(paths: paths).getAll(), isEmpty);
    expect(Directory(p.join(home.path, 'handbook')).existsSync(), isFalse);
  });

  test('a preset email at the wrong domain stops the run', () async {
    final code = await onboard([
      '--name',
      'Dev',
      '--email',
      'work=dev@gmail.com',
      '--email',
      'lab=dev@example-lab.com',
    ]);

    expect(code, ExitCodes.problem);
    expect(out.toString(), contains('Setup stopped: dev@gmail.com is not an @example.com address.'));
    expect(out.toString(), contains('Gita profiles'));
    expect(out.toString(), contains('failed'));
    expect(out.toString(), contains('Finished steps are skipped'));
  });

  test('with no terminal, a missing email says how to pass it', () async {
    final code = await onboard(['--name', 'Dev', '--email', 'lab=dev@example-lab.com']);

    expect(code, ExitCodes.problem);
    expect(out.toString(), contains('No terminal to ask for your @example.com email.'));
    expect(out.toString(), contains('--email work=<email>'));
  });

  test('a failing setup script stops the run with its own messages above', () async {
    File(onboardingPath).writeAsStringSync(jsonEncode(onboarding(unixScript: 'fail.sh', winScript: 'fail.ps1')));

    final code = await onboard([...answers, '--skip-sign-in']);

    expect(code, ExitCodes.problem, reason: '$out$err');
    expect(out.toString(), contains('Setup stopped: The setup script failed'));
  });

  test('--skip-repos leaves repositories and their steps out', () async {
    final code = await onboard([...answers, '--skip-sign-in', '--skip-repos']);

    expect(code, ExitCodes.ok, reason: '$out$err');
    expect(Directory(p.join(home.path, 'handbook')).existsSync(), isFalse);
    expect(out.toString(), contains('skipped (--skip-repos)'));
  });

  test('old .gitconfig backups are listed without a terminal, and deleted with --yes', () async {
    for (final name in [
      '.gitconfig.backup-20250101-090000',
      '.gitconfig.backup-20250201-090000',
      '.gitconfig.backup-20260101-090000',
    ]) {
      File(p.join(home.path, name)).writeAsStringSync('[url "https://x:FAKEVALUE@github.com/"]');
    }

    expect(await onboard([...answers, '--skip-sign-in', '--skip-repos']), ExitCodes.ok, reason: '$out$err');
    expect(out.toString(), contains('kept (2; no terminal to ask)'));
    expect(out.toString(), contains('can still hold GitHub tokens'));
    expect(out.toString(), isNot(contains('FAKEVALUE')));
    expect(File(p.join(home.path, '.gitconfig.backup-20250101-090000')).existsSync(), isTrue);

    out.clear();
    expect(await onboard([...answers, '--skip-sign-in', '--skip-repos', '--yes']), ExitCodes.ok, reason: '$out$err');
    // With --yes the clean-up may first remove the test's insteadOf rule and make a fresh
    // backup (it does on Windows), which then is the newest; either way only the newest
    // backup is left and both 2025 ones are gone.
    expect(out.toString(), matches(RegExp(r'deleted [23]\b')), reason: '$out');
    final left = [
      for (final e in home.listSync())
        if (p.basename(e.path).startsWith('.gitconfig.backup-')) p.basename(e.path),
    ];
    expect(left, hasLength(1), reason: 'only the newest backup is left: $left');
    expect(left.single, isNot(startsWith('.gitconfig.backup-2025')));
  });

  test('a bad onboarding file or an unknown --email account is a usage error', () async {
    File(onboardingPath).writeAsStringSync('{"format": 1, "name": "X", "accounts": [], "steps": []}');
    expect(await onboard([]), ExitCodes.usage);
    expect(err.toString(), contains('needs at least 1 entry'));

    File(onboardingPath).writeAsStringSync(jsonEncode(onboarding()));
    expect(await onboard(['--email', 'nobody=a@b.c']), ExitCodes.usage);
    expect(err.toString(), contains('"nobody" is not an account'));
  });
}
