import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';

/// `gita gh`: runs a fake `gh` (a shell script on a temp PATH) so no real
/// GitHub CLI, account or token is involved. The fake says which test
/// token it got, never the token itself.
void main() {
  late Directory home;
  late Directory workspace;
  late Directory bin;
  late String repoPath;
  late PlatformPaths paths;
  late GitService git;
  late StringBuffer out;
  late StringBuffer err;
  late TokenStore tokens;

  const workToken = 'test-token-work';
  const personalToken = 'test-token-personal';

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
    label: 'My Stuff',
    gitName: 'Dev',
    gitEmail: 'dev@home.example.com',
    colorArgb: 0xFF00AA00,
    createdAt: DateTime(2026, 1, 2),
  );

  const fakeGh = r'''#!/bin/sh
case "$GH_TOKEN" in
  test-token-work) echo "as=work" ;;
  test-token-personal) echo "as=personal" ;;
  "") echo "as=none" ;;
  *) echo "as=other" ;;
esac
echo "github_token=${GITHUB_TOKEN:-unset}"
echo "pwd=$(pwd -P)"
echo "args=$*"
echo "to-stderr" >&2
exit ${FAKE_GH_EXIT:-0}
''';

  /// Captures gh's output instead of attaching it to the terminal.
  Future<int> capture(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
    );
    out.write(result.stdout);
    err.write(result.stderr);
    return result.exitCode;
  }

  Map<String, String> envWithFakeGh({Map<String, String> extra = const {}}) => {
        'PATH': '${bin.path}:/usr/bin:/bin',
        'HOME': home.path,
        'GITHUB_TOKEN': 'some-other-token',
        ...extra,
      };

  Future<int> run(
    List<String> args, {
    String? cwd,
    Map<String, String>? environment,
    bool realRunner = false,
  }) =>
      GitaCli(
        out: out,
        err: err,
        paths: paths,
        gitService: git,
        tokenStore: tokens,
        cwd: cwd ?? repoPath,
        environment: environment ?? envWithFakeGh(),
        runInteractive: realRunner ? null : capture,
      ).run(args);

  Future<void> addProfiles() async {
    final repo = ProfileRepository(paths: paths);
    await repo.upsert(work);
    await repo.upsert(personal);
  }

  Future<void> addRule(RepoRule rule) => RepoRuleRepository(paths: paths).upsert(rule);

  RepoRule folderRuleFor(Profile profile) => RepoRule(
        id: 'folder-${profile.id}',
        pathPattern: resolveRepoPath(workspace.path),
        profileId: profile.id,
      );

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_gh_home_');
    workspace = await Directory.systemTemp.createTemp('gita_gh_ws_');
    bin = await Directory.systemTemp.createTemp('gita_gh_bin_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    git = GitService(environmentOverride: {
      'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
      'GIT_CONFIG_SYSTEM': '${home.path}/gitconfig_system',
    });
    final repo = Directory('${workspace.path}/project')..createSync();
    repoPath = repo.path;
    expect((await Process.run('git', ['init'], workingDirectory: repoPath)).exitCode, 0);

    final gh = File('${bin.path}/gh')..writeAsStringSync(fakeGh);
    expect((await Process.run('chmod', ['755', gh.path])).exitCode, 0);

    out = StringBuffer();
    err = StringBuffer();
    tokens = TokenStore(keychain: InMemoryKeychainStore());
    await tokens.saveToken(work.id, workToken);
    await tokens.saveToken(personal.id, personalToken);
  });

  tearDown(() async {
    for (final dir in [home, workspace, bin]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  void expectNoTokenShown() {
    final all = '$out$err';
    expect(all, isNot(contains(workToken)));
    expect(all, isNot(contains(personalToken)));
  }

  group('gita gh', skip: Platform.isWindows ? 'uses a shell script as gh' : null, () {
    test('runs gh as the profile of the folder rule, in the project', () async {
      await addProfiles();
      await addRule(folderRuleFor(work));

      final code = await run(['gh', 'pr', 'create', '--fill']);

      expect(code, ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains('as=work'));
      expect(out.toString(), contains('args=pr create --fill'));
      expect(out.toString(), contains('pwd=${Directory(repoPath).resolveSymbolicLinksSync()}'));
      expect(err.toString(), contains('to-stderr'));
      expectNoTokenShown();
    });

    test("drops GITHUB_TOKEN so another account's token can't leak in", () async {
      await addProfiles();
      await addRule(folderRuleFor(work));

      await run(['gh', 'repo', 'view']);

      expect(out.toString(), contains('github_token=unset'));
    });

    test('uses an account rule matched against the remote', () async {
      await addProfiles();
      await addRule(folderRuleFor(work));
      await addRule(RepoRule.account(id: 'acct', owner: 'dev-home', profileId: personal.id));
      await git.setConfigValue(repoPath, 'remote.origin.url', 'https://github.com/dev-home/api.git');

      final code = await run(['gh', 'pr', 'list']);

      expect(code, ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains('as=personal'));
    });

    test('works from a subfolder of the project', () async {
      await addProfiles();
      await addRule(folderRuleFor(work));
      final sub = Directory('$repoPath/lib/src')..createSync(recursive: true);

      final code = await run(['gh', 'issue', 'list'], cwd: sub.path);

      expect(code, ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains('as=work'));
    });

    test('--profile picks the profile by name or id, in both spellings', () async {
      await addProfiles();
      await addRule(folderRuleFor(work));

      expect(await run(['gh', '--profile', 'my stuff', 'pr', 'list']), ExitCodes.ok);
      expect(out.toString(), contains('as=personal'));
      expect(out.toString(), contains('args=pr list'));

      out.clear();
      expect(await run(['gh', '--profile=personal', '--', '--version']), ExitCodes.ok);
      expect(out.toString(), contains('as=personal'));
      expect(out.toString(), contains('args=--version'));
    });

    test("passes gh's own flags, including --json and --help, through", () async {
      await addProfiles();
      await addRule(folderRuleFor(work));

      await run(['gh', 'pr', 'list', '--json', 'number', '--profile', 'x']);
      expect(out.toString(), contains('args=pr list --json number --profile x'));

      out.clear();
      await run(['gh', '--help']);
      expect(out.toString(), contains('args=--help'));
    });

    test("passes gh's exit code through (attached to the terminal)", () async {
      await addProfiles();
      await addRule(folderRuleFor(work));

      final code = await run(
        ['gh', 'pr', 'view'],
        environment: envWithFakeGh(extra: {'FAKE_GH_EXIT': '3'}),
        realRunner: true,
      );

      expect(code, 3, reason: '$err');
    });

    test('stops when no rule covers the project, and says to use --profile', () async {
      await addProfiles();

      final code = await run(['gh', 'pr', 'create']);

      expect(code, ExitCodes.usage);
      expect(err.toString(), contains("can't tell which account"));
      expect(err.toString(), contains('gita gh --profile Work pr create'));
      expect(out.toString(), isEmpty, reason: 'gh must not run');
    });

    test('outside a git project it needs --profile', () async {
      await addProfiles();
      final notRepo = await Directory.systemTemp.createTemp('gita_gh_plain_');
      addTearDown(() => notRepo.delete(recursive: true));

      expect(await run(['gh', 'repo', 'list'], cwd: notRepo.path), ExitCodes.usage);
      expect(err.toString(), contains("isn't a git project"));
      expect(out.toString(), isEmpty);

      expect(await run(['gh', '--profile', 'Work', 'repo', 'list'], cwd: notRepo.path), ExitCodes.ok);
      expect(out.toString(), contains('as=work'));
    });

    test('unknown profile and missing --profile value are usage errors', () async {
      await addProfiles();

      expect(await run(['gh', '--profile', 'nope', 'pr', 'list']), ExitCodes.usage);
      expect(err.toString(), contains('There is no profile called "nope"'));

      err.clear();
      expect(await run(['gh', '--profile']), ExitCodes.usage);
      expect(err.toString(), contains('Say which profile'));
      expect(out.toString(), isEmpty);
    });

    test('no profiles at all is a usage error', () async {
      expect(await run(['gh', 'pr', 'list']), ExitCodes.usage);
      expect(err.toString(), contains('no profiles yet'));
    });

    test('a profile without a sign-in points to gita sign-in', () async {
      await addProfiles();
      await addRule(folderRuleFor(personal));
      await tokens.deleteToken(personal.id);

      final code = await run(['gh', 'pr', 'create']);

      expect(code, ExitCodes.problem);
      expect(err.toString(), contains('no GitHub sign-in saved for "My Stuff"'));
      expect(err.toString(), contains('gita sign-in --profile "My Stuff"'));
      expect(out.toString(), isEmpty);
    });

    test("an unreachable password store is reported, not a crash", () async {
      await addProfiles();
      await addRule(folderRuleFor(work));
      tokens = TokenStore(keychain: _BrokenKeychain());

      expect(await run(['gh', 'pr', 'list']), ExitCodes.problem);
      expect(err.toString(), contains('password store'));
    });

    test("says how to install gh when it isn't on PATH", () async {
      await addProfiles();
      await addRule(folderRuleFor(work));
      final empty = await Directory.systemTemp.createTemp('gita_gh_empty_');
      addTearDown(() => empty.delete(recursive: true));

      final code = await run(['gh', 'pr', 'list'], environment: {'PATH': empty.path});

      expect(code, ExitCodes.problem);
      expect(err.toString(), contains("isn't installed"));
      expect(err.toString(), contains('cli.github.com'));
    });

    test('ignores a gh on PATH that is not executable', () async {
      await addProfiles();
      await addRule(folderRuleFor(work));
      final dir = await Directory.systemTemp.createTemp('gita_gh_noexec_');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/gh').writeAsStringSync(fakeGh);

      final code = await run(['gh', 'pr', 'list'], environment: {'PATH': '${dir.path}:${bin.path}'});

      expect(code, ExitCodes.ok, reason: '$err');
      expect(out.toString(), contains('as=work'));
    });

    test('refuses gh commands that would print the token', () async {
      await addProfiles();
      await addRule(folderRuleFor(work));

      for (final args in [
        ['auth', 'token'],
        ['auth', 'status', '--show-token'],
        ['auth', 'status', '-t'],
        ['--profile', 'Work', 'auth', 'token'],
      ]) {
        err.clear();
        expect(await run(['gh', ...args]), ExitCodes.usage, reason: '$args');
        expect(err.toString(), contains("doesn't show GitHub sign-ins"));
      }
      expect(out.toString(), isEmpty, reason: 'gh must not run');

      expect(await run(['gh', 'auth', 'status']), ExitCodes.ok);
      expect(out.toString(), contains('args=auth status'));
    });

    test('is listed in gita --help', () async {
      expect(await run(['--help']), ExitCodes.ok);
      expect(out.toString(), contains('gh [--profile <name or id>] <gh command...>'));
    });
  });
}

class _BrokenKeychain implements KeychainStore {
  @override
  Future<String?> read(String key) async => throw KeychainException('locked');

  @override
  Future<void> write(String key, String value) async => throw KeychainException('locked');

  @override
  Future<void> delete(String key) async => throw KeychainException('locked');
}
