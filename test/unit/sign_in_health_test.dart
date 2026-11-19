import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/doctor_issue.dart';
import 'package:gita/core/models/mismatch_report.dart' show Severity;
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/core/services/identity_doctor_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/sign_in_checker.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';

import '../support/fake_github.dart';

/// Answers GET /user with a fixed status, or throws.
class _UserApi implements GitHubHttp {
  _UserApi(this.status, {this.body = '{"login":"dev-work"}', this.fail});

  int status;
  String body;
  Exception? fail;
  var calls = 0;
  final tokens = <String>[];

  @override
  Future<GitHubResponse> get(Uri uri, String token) async {
    calls++;
    tokens.add(token);
    expect(uri.toString(), 'https://api.github.com/user');
    if (fail != null) throw fail!;
    return GitHubResponse(status, body);
  }

  @override
  Future<GitHubResponse> post(Uri uri, Map<String, String> form) => throw UnimplementedError();

  @override
  Future<GitHubResponse> postJson(Uri uri, String token, Map<String, Object?> body) =>
      throw UnimplementedError();
}

/// A checker with a scripted answer per token.
class _FakeChecker implements SignInChecker {
  _FakeChecker(this.answers);

  final Map<String, SignInCheck> answers;
  final asked = <String>[];

  @override
  Future<SignInCheck> check(String token) async {
    asked.add(token);
    return answers[token] ?? SignInCheck.unknown;
  }
}

void main() {
  group('GitHubSignInChecker', () {
    test('200 is working, with the account', () async {
      final api = _UserApi(200);
      final result = await GitHubSignInChecker(http: api).check('gho_ok');
      expect(result.health, SignInHealth.working);
      expect(result.login, 'dev-work');
      expect(api.tokens, ['gho_ok']);
    });

    test('401 is rejected', () async {
      final result = await GitHubSignInChecker(http: _UserApi(401)).check('gho_dead');
      expect(result.health, SignInHealth.rejected);
      expect(result.login, isNull);
    });

    test('other answers, bad JSON, errors and timeouts are unknown', () async {
      for (final api in [
        _UserApi(500),
        _UserApi(403),
        _UserApi(200, body: 'not json'),
        _UserApi(200, body: '{"name":"no login"}'),
        _UserApi(200, fail: const SocketException('offline')),
      ]) {
        expect((await GitHubSignInChecker(http: api).check('t')).health, SignInHealth.unknown);
      }
      final slow = _SlowApi();
      final result = await GitHubSignInChecker(http: slow, timeout: const Duration(milliseconds: 10)).check('t');
      expect(result.health, SignInHealth.unknown);
      slow.release.complete();
    });

    test('an empty token is rejected without asking GitHub', () async {
      final api = _UserApi(200);
      expect((await GitHubSignInChecker(http: api).check('')).health, SignInHealth.rejected);
      expect(api.calls, 0);
    });

    test('keeps clear answers for a while, but not unknown ones', () async {
      var now = DateTime(2026, 11, 11, 9);
      final api = _UserApi(401);
      final checker = GitHubSignInChecker(http: api, now: () => now);

      await checker.check('a');
      await checker.check('a');
      expect(api.calls, 1, reason: 'cached');

      now = now.add(const Duration(minutes: 6));
      await checker.check('a');
      expect(api.calls, 2, reason: 'cache ran out');

      await checker.check('b');
      expect(api.calls, 3, reason: 'a different token is asked about');

      api.status = 500;
      await checker.check('c');
      await checker.check('c');
      expect(api.calls, 5, reason: 'unknown is asked again');
    });
  });

  group('Doctor sign-in health', () {
    late Directory home;
    late PlatformPaths paths;
    late TokenStore tokens;

    final work = Profile(
      id: 'work',
      label: 'Work',
      gitName: 'Dev',
      gitEmail: 'dev@work.example.com',
      colorArgb: 0xFF0000AA,
      createdAt: DateTime(2026, 1, 1),
      githubLogin: 'dev-work',
    );

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_health_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      tokens = TokenStore(keychain: InMemoryKeychainStore());
      File(paths.cliPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('fake');
    });

    tearDown(() async {
      if (home.existsSync()) await home.delete(recursive: true);
    });

    Future<List<DoctorIssue>> doctor(SignInChecker? checker, {Profile? profile}) =>
        IdentityDoctorService(paths: paths, tokenStore: tokens, signInChecker: checker)
            .run(profiles: [profile ?? work], rules: const [], sshKeys: const []);

    test('a rejected sign-in is blocking and offers to sign in', () async {
      await tokens.saveToken('work', 'gho_dead');
      final issues = await doctor(_FakeChecker({'gho_dead': SignInCheck.rejected}));
      final issue = issues.single;
      expect(issue.category, DoctorCategory.signInRejected);
      expect(issue.severity, Severity.blocking);
      expect(issue.profileId, 'work');
      expect(issue.message, contains('"Work"'));
      expect(issue.message, contains('stopped working'));
      expect(issue.message, contains('Sign in with GitHub'));
      expect(issue.message, isNot(contains('gho_dead')), reason: 'never show the token');
    });

    test('a sign-in for another account is a warning', () async {
      await tokens.saveToken('work', 'gho_other');
      final issues = await doctor(_FakeChecker({'gho_other': const SignInCheck.working('someone-else')}));
      expect(issues.single.category, DoctorCategory.signInWrongAccount);
      expect(issues.single.severity, Severity.warning);
      expect(issues.single.message, contains('@dev-work'));
      expect(issues.single.message, contains('@someone-else'));
    });

    test('a working sign-in, the same account in other case, or no answer is fine', () async {
      await tokens.saveToken('work', 'gho_ok');
      expect(await doctor(_FakeChecker({'gho_ok': const SignInCheck.working('Dev-Work')})), isEmpty);
      expect(await doctor(_FakeChecker({})), isEmpty, reason: 'unknown says nothing');
      expect(
        await doctor(_FakeChecker({'gho_ok': const SignInCheck.working('anyone')}),
            profile: work.copyWith(clearGithubLogin: true)),
        isEmpty,
        reason: 'no expected account to compare with',
      );
    });

    test('without a checker, or without a token, GitHub is not asked', () async {
      expect(await doctor(null), hasLength(1)); // missingPushToken
      final checker = _FakeChecker({});
      final issues = await doctor(checker);
      expect(issues.single.category, DoctorCategory.missingPushToken);
      expect(checker.asked, isEmpty);

      await tokens.saveToken('work', 'gho_dead');
      expect(await doctor(null), isEmpty);
    });
  });

  group('gita CLI', () {
    late Directory home;
    late PlatformPaths paths;
    late StringBuffer out;
    late StringBuffer err;
    late TokenStore tokens;

    final work = Profile(
      id: 'work',
      label: 'Work',
      gitName: 'Dev',
      gitEmail: 'dev@work.example.com',
      colorArgb: 0xFF0000AA,
      createdAt: DateTime(2026, 1, 1),
      githubLogin: 'dev-work',
    );
    const request = 'protocol=https\nhost=github.com\n\n';

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_health_cli_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      out = StringBuffer();
      err = StringBuffer();
      tokens = TokenStore(keychain: InMemoryKeychainStore());
      await ProfileRepository(paths: paths).upsert(work);
      File(paths.cliPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('fake');
    });

    tearDown(() async {
      if (home.existsSync()) await home.delete(recursive: true);
    });

    Future<int> run(List<String> args, SignInChecker? checker, {FakeGitHub? github, String stdin = ''}) =>
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
          signInChecker: checker,
          deviceFlow: GitHubDeviceFlow(
            clientId: 'Ov23liTEST',
            http: github ??
                FakeGitHub(
                  tokenAnswers: [
                    {'access_token': 'gho_new', 'token_type': 'bearer'},
                  ],
                  user: {'login': 'dev-work'},
                ),
            delay: (_) async {},
          ),
          openBrowser: (_) async => true,
        ).run(args);

    group('credential erase', () {
      test('a cancelled sign-in says so and gives one step', () async {
        await tokens.saveToken('work', 'gho_dead');
        await run(['credential', '--profile', 'work', 'erase'],
            _FakeChecker({'gho_dead': SignInCheck.rejected}), stdin: request);

        final text = err.toString();
        expect(text, contains('"Work"\'s GitHub sign-in has stopped working'));
        expect(text, contains('Sign in with GitHub'));
        expect(text, contains('gita sign-in --profile work'));
        expect(text, isNot(contains('gho_dead')));
        expect(out.toString(), isEmpty, reason: 'git reads stdout');
        expect(await tokens.readToken('work'), 'gho_dead', reason: 'the token is kept');
      });

      test('a working sign-in says signing in again will not help', () async {
        await tokens.saveToken('work', 'gho_ok');
        await run(['credential', '--profile', 'work', 'erase'],
            _FakeChecker({'gho_ok': const SignInCheck.working('dev-work')}), stdin: request);

        expect(err.toString(), contains('signed in as @dev-work and that sign-in works'));
        expect(err.toString(), contains('Signing in again will not help'));
      });

      test('a sign-in for the wrong account says which one to use', () async {
        await tokens.saveToken('work', 'gho_other');
        await run(['credential', '--profile', 'work', 'erase'],
            _FakeChecker({'gho_other': const SignInCheck.working('someone-else')}), stdin: request);

        expect(err.toString(), contains('@someone-else'));
        expect(err.toString(), contains('sign it in again as @dev-work'));
      });

      test('no answer from GitHub keeps the general advice', () async {
        await tokens.saveToken('work', 'gho_x');
        await run(['credential', '--profile', 'work', 'erase'], null, stdin: request);

        expect(err.toString(), contains('did not accept'));
        expect(err.toString(), contains('if this keeps happening'));
      });
    });

    group('sign-in', () {
      test('does nothing when the saved sign-in works for the right account', () async {
        await tokens.saveToken('work', 'gho_ok');
        final github = FakeGitHub();
        final code = await run(['sign-in', '--profile', 'work'],
            _FakeChecker({'gho_ok': const SignInCheck.working('dev-work')}), github: github);

        expect(code, ExitCodes.ok);
        expect(out.toString(), contains('already signed in as @dev-work'));
        expect(out.toString(), contains('--force'));
        expect(github.posts, isEmpty, reason: 'no new sign-in was started');
        expect(await tokens.readToken('work'), 'gho_ok');
      });

      test('--json says alreadySignedIn', () async {
        await tokens.saveToken('work', 'gho_ok');
        await run(['sign-in', '--profile', 'work', '--no-wait', '--json'],
            _FakeChecker({'gho_ok': const SignInCheck.working('dev-work')}));

        final json = jsonDecode(out.toString()) as Map<String, dynamic>;
        expect(json['ok'], isTrue);
        expect(json['alreadySignedIn'], isTrue);
        expect(json['githubLogin'], 'dev-work');
        expect(out.toString(), isNot(contains('gho_ok')));
      });

      test('signs in when the saved sign-in was cancelled', () async {
        await tokens.saveToken('work', 'gho_dead');
        final code = await run(['sign-in', '--profile', 'work', '--no-browser'],
            _FakeChecker({'gho_dead': SignInCheck.rejected}));

        expect(code, ExitCodes.ok, reason: '$out$err');
        expect(out.toString(), contains('Done: "Work" is signed in as @dev-work'));
        expect(await tokens.readToken('work'), 'gho_new');
      });

      test('signs in when the saved sign-in is for another account', () async {
        await tokens.saveToken('work', 'gho_other');
        await run(['sign-in', '--profile', 'work', '--no-browser'],
            _FakeChecker({'gho_other': const SignInCheck.working('someone-else')}));

        expect(await tokens.readToken('work'), 'gho_new');
      });

      test('--force signs in even when the sign-in works', () async {
        await tokens.saveToken('work', 'gho_ok');
        final checker = _FakeChecker({'gho_ok': const SignInCheck.working('dev-work')});
        await run(['sign-in', '--profile', 'work', '--no-browser', '--force'], checker);

        expect(checker.asked, isEmpty);
        expect(await tokens.readToken('work'), 'gho_new');
      });
    });

    test('doctor reports a cancelled sign-in, without the token', () async {
      await tokens.saveToken('work', 'gho_dead');
      final code = await run(['doctor', '--json'], _FakeChecker({'gho_dead': SignInCheck.rejected}));

      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      final issues = json['issues'] as List;
      expect([for (final i in issues) i['category']], ['signInRejected']);
      expect(code, isNot(ExitCodes.ok), reason: 'it is blocking');
      expect(out.toString(), isNot(contains('gho_dead')));
    });
  });
}

/// Never answers until [release] completes.
class _SlowApi extends _UserApi {
  _SlowApi() : super(200);

  final release = Completer<void>();

  @override
  Future<GitHubResponse> get(Uri uri, String token) async {
    await release.future;
    return const GitHubResponse(200, '{"login":"late"}');
  }
}
