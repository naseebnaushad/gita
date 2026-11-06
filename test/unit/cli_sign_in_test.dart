import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';

/// `gita sign-in` and `gita profiles`, against a temp home and a scripted
/// GitHub, so no real account or keychain is touched.
void main() {
  late Directory home;
  late PlatformPaths paths;
  late StringBuffer out;
  late StringBuffer err;
  late TokenStore tokens;
  late List<Uri> opened;

  final work = Profile(
    id: 'work',
    label: 'Work',
    gitName: 'Dev Work',
    gitEmail: 'dev@work.example.com',
    colorArgb: 0xFF0000AA,
    createdAt: DateTime(2026, 1, 1),
  );
  final personal = Profile(
    id: 'personal',
    label: 'Personal',
    gitName: 'Dev',
    gitEmail: 'dev@home.example.com',
    colorArgb: 0xFF00AA00,
    createdAt: DateTime(2026, 1, 2),
  );

  FakeGitHub signedInGitHub({
    String login = 'dev-work',
    String email = 'dev@work.example.com',
    int userStatus = 200,
    List<Map<String, Object?>>? tokenAnswers,
  }) =>
      FakeGitHub(
        tokenAnswers: tokenAnswers ??
            [
              {'error': 'authorization_pending'},
              {'access_token': 'gho_device', 'token_type': 'bearer'},
            ],
        user: {'login': login, 'name': 'Dev'},
        emails: [
          {'email': email, 'primary': true, 'verified': true},
        ],
        userStatus: userStatus,
      );

  Future<int> run(
    List<String> args, {
    FakeGitHub? github,
    String stdin = '',
  }) =>
      GitaCli(
        out: out,
        err: err,
        paths: paths,
        gitService: GitService(environmentOverride: {
          'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
          'GIT_CONFIG_SYSTEM': '${home.path}/gitconfig_system',
        }),
        tokenStore: tokens,
        input: Stream.value(utf8.encode(stdin)),
        deviceFlow: GitHubDeviceFlow(
          clientId: 'Ov23liTEST',
          http: github ?? signedInGitHub(),
          delay: (_) async {},
        ),
        openBrowser: (url) async {
          opened.add(url);
          return true;
        },
      ).run(args);

  String includeFile(String id) =>
      File(p.join(paths.profilesDir, '$id.gitconfig')).readAsStringSync();

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_signin_home_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    out = StringBuffer();
    err = StringBuffer();
    tokens = TokenStore(keychain: InMemoryKeychainStore());
    opened = [];
    await ProfileRepository(paths: paths).upsert(work);
    await ProfileRepository(paths: paths).upsert(personal);
    await RepoRuleRepository(paths: paths).upsert(
      const RepoRule(id: 'r1', pathPattern: 'C:/work/', profileId: 'work'),
    );
    // The credential helper is only written when the CLI is installed.
    File(paths.cliPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('fake');
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  group('gita sign-in (device flow)', () {
    test('shows the code, opens the browser, saves the token and account', () async {
      final github = signedInGitHub();
      final code = await run(['sign-in', '--profile', 'work'], github: github);

      expect(code, 0, reason: '$out$err');
      final text = out.toString();
      expect(text, contains('WDJB-MJHT'));
      expect(text, contains('https://github.com/login/device'));
      expect(text, contains('Done: "Work" is signed in as @dev-work'));
      expect(opened, [Uri.parse('https://github.com/login/device')]);
      expect(github.polls, 2);

      expect(await tokens.readToken('work'), 'gho_device');
      expect(await tokens.hasToken('personal'), isFalse);
      final saved = await ProfileRepository(paths: paths).getAll();
      expect(saved.firstWhere((p) => p.id == 'work').githubLogin, 'dev-work');
      expect(saved.firstWhere((p) => p.id == 'personal').githubLogin, isNull);
    });

    test('turns on the HTTPS credential helper for that profile only', () async {
      expect(await run(['sign-in', '--profile', 'work']), 0, reason: '$out$err');

      final workFile = includeFile('work');
      expect(workFile, contains('[credential "https://github.com"]'));
      expect(workFile, contains('credential --profile work'));
      expect(workFile, contains('email = dev@work.example.com'));
      expect(includeFile('personal'), isNot(contains('credential --profile')));

      final gitconfig = File(paths.gitConfigPath).readAsStringSync();
      expect(gitconfig, contains('gitdir/i:C:/work/'));
    });

    test('finds the profile by its label, ignoring case', () async {
      expect(await run(['sign-in', '--profile', 'WORK']), 0, reason: '$out$err');
      expect(await tokens.hasToken('work'), isTrue);
    });

    test('--no-browser does not open the browser', () async {
      expect(await run(['sign-in', '--profile', 'work', '--no-browser']), 0);
      expect(opened, isEmpty);
      expect(out.toString(), contains('WDJB-MJHT'));
    });

    test('notes a different main email and a switched account', () async {
      await ProfileRepository(paths: paths).upsert(work.copyWith(githubLogin: 'old-login'));
      final github = signedInGitHub(login: 'new-login', email: 'other@example.com');

      expect(await run(['sign-in', '--profile', 'work'], github: github), 0);

      final text = out.toString();
      expect(text, contains('was signed in as @old-login before; it now uses @new-login'));
      expect(text, contains("main email is other@example.com"));
    });

    test('--json prints the code step, then the result', () async {
      expect(await run(['sign-in', '--profile', 'work', '--json']), 0, reason: '$out$err');

      final lines = out.toString().trim().split('\n');
      expect(jsonDecode(lines.first), {
        'step': 'enter-code',
        'code': 'WDJB-MJHT',
        'url': 'https://github.com/login/device',
      });
      final result = jsonDecode(lines.skip(1).join('\n')) as Map<String, dynamic>;
      expect(result['ok'], isTrue);
      expect(result['profile'], 'work');
      expect(result['githubLogin'], 'dev-work');
      expect(result.containsKey('note'), isFalse);
      expect(result.containsKey('previousLogin'), isFalse);
    });

    test('a denied sign-in says so plainly and saves nothing', () async {
      final github = signedInGitHub(tokenAnswers: [
        {'error': 'access_denied'},
      ]);

      expect(await run(['sign-in', '--profile', 'work'], github: github), 1);
      expect(err.toString(), isNotEmpty);
      expect(await tokens.hasToken('work'), isFalse);
      expect(File(p.join(paths.profilesDir, 'work.gitconfig')).existsSync(), isFalse);
      final saved = await ProfileRepository(paths: paths).getAll();
      expect(saved.firstWhere((p) => p.id == 'work').githubLogin, isNull);
    });
  });

  group('gita sign-in --with-token', () {
    test('reads the token from stdin and signs in', () async {
      final github = signedInGitHub();
      final code = await run(
        ['sign-in', '--profile', 'personal', '--with-token'],
        github: github,
        stdin: '  ghp_pasted\n',
      );

      expect(code, 0, reason: '$out$err');
      expect(await tokens.readToken('personal'), 'ghp_pasted');
      expect(github.posts, isEmpty, reason: 'no device flow');
      expect(github.gets.first.$2, 'ghp_pasted');
      expect(opened, isEmpty);
      expect(includeFile('personal'), contains('credential --profile personal'));
    });

    test('an empty token is a usage error', () async {
      expect(await run(['sign-in', '--profile', 'work', '--with-token'], stdin: '\n'), 2);
      expect(err.toString(), contains('No token was given'));
      expect(await tokens.hasToken('work'), isFalse);
    });

    test('a token GitHub refuses gives a clear message and saves nothing', () async {
      final github = signedInGitHub(userStatus: 401);
      final code = await run(
        ['sign-in', '--profile', 'work', '--with-token'],
        github: github,
        stdin: 'ghp_bad',
      );

      expect(code, 1);
      expect(err.toString(), contains("GitHub didn't accept this token"));
      expect(await tokens.hasToken('work'), isFalse);
    });
  });

  group('gita sign-in mistakes', () {
    test('without --profile is a usage error', () async {
      expect(await run(['sign-in']), 2);
      expect(err.toString(), contains('--profile'));
    });

    test('an unknown profile lists the ones there are', () async {
      expect(await run(['sign-in', '--profile', 'nope']), 2);
      expect(err.toString(), contains('no profile called "nope"'));
      expect(err.toString(), contains('"Work" (work)'));
      expect(err.toString(), contains('"Personal" (personal)'));
    });

    test('--help explains the command', () async {
      expect(await run(['sign-in', '--help']), 0);
      expect('$out$err', contains('--with-token'));
    });
  });

  group('gita profiles', () {
    test('lists each profile with sign-in, SSH key and folders', () async {
      await tokens.saveToken('work', 'gho_x');
      expect(await run(['profiles']), 0);

      final text = out.toString();
      expect(text, contains('Work  (id: work)'));
      expect(text, contains('Commits as:      Dev Work <dev@work.example.com>'));
      expect(text, contains('GitHub sign-in:  saved'));
      expect(text, contains('Folders:         C:/work/'));
      expect(text, contains('run "gita sign-in --profile personal"'));
      expect(text, contains('none yet'));
    });

    test('--json gives the same facts', () async {
      expect(await run(['profiles', '--json']), 0);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(json['ok'], isTrue);
      final rows = (json['profiles'] as List).cast<Map<String, dynamic>>();
      final w = rows.firstWhere((r) => r['id'] == 'work');
      expect(w['email'], 'dev@work.example.com');
      expect(w['signedIn'], isFalse);
      expect(w['sshKey'], isFalse);
      expect(w['folders'], ['C:/work/']);
    });

    test('with no profiles says how to add one', () async {
      File(paths.profilesJsonPath).deleteSync();
      expect(await run(['profiles']), 0);
      expect(out.toString(), contains('No profiles yet'));
    });
  });
}
