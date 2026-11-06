import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/gitconfig_service.dart';
import 'package:gita/core/services/hook_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';

/// End-to-end tests for the headless CLI: real git, real includeIf
/// resolution, but against a temp home dir so the developer's own
/// ~/.gitconfig and ~/.gita are never read or touched.
void main() {
  late Directory home;
  late Directory workspace;
  late String repoPath;
  late PlatformPaths paths;
  late GitService git;
  late StringBuffer out;
  late StringBuffer err;
  late TokenStore tokens;

  final aiProfile = Profile(
    id: 'ai',
    label: 'AI projects',
    gitName: 'Dev (AI)',
    gitEmail: 'dev@ai.example.com',
    colorArgb: 0xFF00AA00,
    createdAt: DateTime(2026, 1, 1),
  );

  Future<int> run(List<String> args, {String stdin = ''}) => GitaCli(
        out: out,
        err: err,
        paths: paths,
        gitService: git,
        tokenStore: tokens,
        input: Stream.value(utf8.encode(stdin)),
      ).run(args);

  Future<void> assignWorkspaceTo(Profile profile) async {
    await ProfileRepository(paths: paths).upsert(profile);
    final rule = RepoRule(
      id: 'rule-1',
      pathPattern: resolveRepoPath(workspace.path),
      profileId: profile.id,
    );
    await RepoRuleRepository(paths: paths).upsert(rule);
    final gitConfig = GitConfigService(paths: paths);
    await gitConfig.writeProfileConfigFile(profile);
    await gitConfig.syncManagedIncludeIfBlock(
      rules: [rule],
      profilesById: {profile.id: profile},
    );
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_cli_home_');
    workspace = await Directory.systemTemp.createTemp('gita_cli_ws_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    git = GitService(environmentOverride: {
      'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
      'GIT_CONFIG_SYSTEM': '${home.path}/gitconfig_system',
    });
    final repo = Directory('${workspace.path}/project')..createSync();
    repoPath = repo.path;
    final init = await Process.run('git', ['init'], workingDirectory: repoPath);
    expect(init.exitCode, 0);
    out = StringBuffer();
    err = StringBuffer();
    tokens = TokenStore(keychain: InMemoryKeychainStore());
  });

  tearDown(() async {
    for (final dir in [home, workspace]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  group('check', () {
    test('passes when the folder rule gives the expected identity', () async {
      await assignWorkspaceTo(aiProfile);
      await HookService(paths: paths, git: git).install(repoPath);

      final code = await run(['check', repoPath]);

      expect(code, ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains('AI projects <dev@ai.example.com>'));
      expect(out.toString(), contains('All good'));
    });

    test('passes but gives a heads-up when the safety check is missing', () async {
      await assignWorkspaceTo(aiProfile);

      final code = await run(['check', repoPath]);

      expect(code, ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains("doesn't have Gita's safety check"));
      expect(out.toString(), contains('gita guard install'));
    });

    test('fails when a repo-local email overrides the profile', () async {
      await assignWorkspaceTo(aiProfile);
      await git.setConfigValue(repoPath, 'user.email', 'old@work.example.com');

      final code = await run(['check', repoPath]);

      expect(code, ExitCodes.problem);
      expect(out.toString(), contains('PROBLEM'));
      expect(out.toString(), contains('old@work.example.com'));
      expect(out.toString(), contains('What to do:'));
    });

    test('warns but does not fail when no rule covers the repo', () async {
      final code = await run(['check', repoPath]);

      expect(code, ExitCodes.ok);
      expect(out.toString(), contains('Heads up'));
    });

    test('--json reports the mismatch in a stable shape', () async {
      await assignWorkspaceTo(aiProfile);
      await git.setConfigValue(repoPath, 'user.email', 'old@work.example.com');

      final code = await run(['check', '--json', repoPath]);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;

      expect(code, ExitCodes.problem);
      expect(json['ok'], isFalse);
      expect(json['actualEmail'], 'old@work.example.com');
      expect(json['expectedProfile']['id'], 'ai');
      expect(json['issue']['type'], 'identityMismatch');
      expect(json['issue']['severity'], 'blocking');
    });

    test('exits with a usage error outside a git project', () async {
      final code = await run(['check', home.path]);

      expect(code, ExitCodes.usage);
      expect(err.toString(), contains("isn't a git project"));
    });
  });

  group('which', () {
    test('never fails on a mismatch — it only reports', () async {
      await assignWorkspaceTo(aiProfile);
      await git.setConfigValue(repoPath, 'user.email', 'old@work.example.com');

      final code = await run(['which', repoPath]);

      expect(code, ExitCodes.ok);
      expect(out.toString(), contains('Should use:   AI projects'));
      expect(out.toString(), contains('Commits as:   old@work.example.com'));
    });
  });

  group('doctor', () {
    test('tells the user to set up Gita when there are no profiles', () async {
      final code = await run(['doctor']);

      expect(code, ExitCodes.ok);
      expect(out.toString(), contains("isn't set up"));
    });

    test('--json lists issues such as a rule pointing at a deleted profile',
        () async {
      await ProfileRepository(paths: paths).upsert(aiProfile);
      await tokens.saveToken('ai', 'ghp_test');
      File(paths.cliPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      await RepoRuleRepository(paths: paths).upsert(
        const RepoRule(id: 'r', pathPattern: '/x', profileId: 'gone'),
      );

      final code = await run(['doctor', '--json']);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;

      expect(code, ExitCodes.ok); // orphaned rule is a warning, not blocking
      expect(json['configured'], isTrue);
      final issues = json['issues'] as List;
      expect(issues.single['category'], 'orphanedRuleProfile');
    });
  });

  group('doctor HTTPS sign-in', () {
    Future<List<String>> categories() async {
      out.clear();
      await run(['doctor', '--json']);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      return [for (final i in json['issues'] as List) i['category'] as String];
    }

    test('flags a profile with no saved token', () async {
      await ProfileRepository(paths: paths).upsert(aiProfile);
      expect(await categories(), ['missingPushToken']);
    });

    test('flags a saved token the gita command cannot use yet', () async {
      await ProfileRepository(paths: paths).upsert(aiProfile);
      await tokens.saveToken('ai', 'ghp_test');
      expect(await categories(), ['credentialHelperNotInstalled']);

      File(paths.cliPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      expect(await categories(), isEmpty);
    });
  });

  group('credential helper', () {
    String lines(List<String> l) => '${l.join('\n')}\n\n';
    final request = lines(['protocol=https', 'host=github.com']);

    setUp(() => ProfileRepository(paths: paths).upsert(aiProfile));

    test('get answers with the profile token', () async {
      await tokens.saveToken('ai', 'ghp_secret');

      final code = await run(['credential', '--profile', 'ai', 'get'],
          stdin: request);

      expect(code, ExitCodes.ok);
      expect(const LineSplitter().convert(out.toString()),
          ['username=x-access-token', 'password=ghp_secret']);
      expect(err.toString(), isEmpty);
    });

    test('get keeps the username git sent', () async {
      await tokens.saveToken('ai', 'ghp_secret');

      await run(['credential', '--profile', 'ai', 'get'],
          stdin: lines(
              ['protocol=https', 'host=github.com', 'username=dev-ai']));

      expect(const LineSplitter().convert(out.toString()).first,
          'username=dev-ai');
    });

    test('get without a token stops git and says how to fix it', () async {
      final code = await run(['credential', '--profile', 'ai', 'get'],
          stdin: request);

      expect(code, ExitCodes.ok);
      expect(out.toString().trim(), 'quit=1');
      expect(err.toString(), contains('"AI projects"'));
      expect(err.toString(), contains('Profiles'));
    });

    test('erase keeps the token and explains the rejection', () async {
      await tokens.saveToken('ai', 'ghp_secret');

      await run(['credential', '--profile', 'ai', 'erase'], stdin: request);

      expect(await tokens.readToken('ai'), 'ghp_secret');
      expect(err.toString(), contains('did not accept'));
      expect(out.toString(), isEmpty);
    });

    test('store is a no-op', () async {
      await run(['credential', '--profile', 'ai', 'store'],
          stdin: lines([
            'protocol=https',
            'host=github.com',
            'username=u',
            'password=other',
          ]));

      expect(await tokens.readToken('ai'), isNull);
      expect(out.toString(), isEmpty);
    });

    test('missing --profile is a usage error', () async {
      expect(await run(['credential', 'get']), ExitCodes.usage);
    });
  });


  group('arguments', () {
    test('no command prints usage and exits 2', () async {
      expect(await run([]), ExitCodes.usage);
      expect(err.toString(), contains('Usage: gita'));
    });

    test('unknown command is named in the error', () async {
      expect(await run(['nope']), ExitCodes.usage);
      expect(err.toString(), contains('Unknown command: nope'));
    });

    test('--help exits 0', () async {
      expect(await run(['--help']), ExitCodes.ok);
      expect(await run(['check', '--help']), ExitCodes.ok);
    });
  });

  group('commands that change the setup', () {
    Map<String, dynamic> lastJson() {
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      out.clear();
      return json;
    }

    Future<void> gitRepo(String path, String email) async {
      Directory(path).createSync(recursive: true);
      for (final args in [
        ['init', '-q'],
        ['config', 'user.email', email],
        ['config', 'user.name', 'Dev'],
      ]) {
        expect((await git.raw(args, workingDir: path)).exitCode, 0);
      }
    }

    Future<String> emailIn(String dir) async =>
        (await git.raw(['config', 'user.email'], workingDir: dir)).stdout.toString().trim();

    test('profile add saves the profile and makes its folders use it', () async {
      final code = await run([
        'profile', '--name', 'Jane Doe', '--email', 'jane@acme.com', '--label', 'Work',
        '--folder', workspace.path, 'add', '--json',
      ]);
      expect(code, ExitCodes.ok, reason: '$out$err');
      final json = lastJson();
      expect(json['profile']['label'], 'Work');
      expect(json['profile']['email'], 'jane@acme.com');
      expect(json['folders'], hasLength(1));

      // git itself now commits as Jane in that folder.
      expect(await emailIn(repoPath), 'jane@acme.com');

      // Same email, same label, a bad email and a missing name are refused.
      expect(await run(['profile', '--name', 'J', '--email', 'JANE@acme.com', 'add']), ExitCodes.usage);
      expect(err.toString(), contains('already a profile for JANE@acme.com'));
      expect(await run(['profile', '--name', 'J', '--email', 'j@x.com', '--label', 'work', 'add']), ExitCodes.usage);
      expect(err.toString(), contains('already a profile called "work"'));
      expect(await run(['profile', '--name', 'J', '--email', 'not-an-email', 'add']), ExitCodes.usage);
      expect(err.toString(), contains('not an email address'));
      expect(await run(['profile', '--email', 'j@x.com', 'add']), ExitCodes.usage);
      expect(await ProfileRepository(paths: paths).getAll(), hasLength(1));
    });

    test('profile edit changes a profile, and says when there is nothing to change', () async {
      await assignWorkspaceTo(aiProfile);

      expect(await run(['profile', '--email', 'new@ai.example.com', 'edit', 'AI projects']), ExitCodes.ok,
          reason: '$out$err');
      expect(out.toString(), contains('new@ai.example.com'));
      expect(await emailIn(repoPath), 'new@ai.example.com');

      expect(await run(['profile', 'edit', 'ai']), ExitCodes.usage);
      expect(err.toString(), contains('Nothing to change'));
      expect(await run(['profile', '--name', 'X', 'edit', 'nobody']), ExitCodes.usage);
      expect(err.toString(), contains('no profile called "nobody"'));
      expect(await run(['profile', 'remove', 'ai']), ExitCodes.usage);
    });

    test('rule add, list and remove', () async {
      await assignWorkspaceTo(aiProfile);
      await run(['profile', '--name', 'Me', '--email', 'me@gmail.com', '--label', 'Personal', 'add']);
      out.clear();

      // A folder rule for the same folder is replaced, not added twice.
      expect(await run(['rule', '--profile', 'Personal', '--folder', workspace.path, 'add', '--json']),
          ExitCodes.ok, reason: '$out$err');
      final replaced = lastJson();
      expect(replaced['replacedProfile'], 'ai');
      expect(replaced['rule']['id'], 'rule-1');
      expect(replaced['message'], contains('instead of "AI projects"'));
      expect(await emailIn(repoPath), 'me@gmail.com');

      expect(await run(['rule', '--profile', 'ai', '--owner', '@acme', 'add']), ExitCodes.ok, reason: '$err');
      expect(out.toString(), contains('Projects from github.com/acme now use "AI projects"'));
      out.clear();

      expect(await run(['rule', 'list']), ExitCodes.ok);
      expect(out.toString(), contains('Projects from github.com/acme  ->  AI projects <dev@ai.example.com>'));
      expect(out.toString(), contains('Personal <me@gmail.com>'));
      out.clear();

      // Neither or both of --folder and --owner, a bad owner, an unknown profile.
      expect(await run(['rule', '--profile', 'ai', 'add']), ExitCodes.usage);
      expect(await run(['rule', '--profile', 'ai', '--owner', 'a', '--folder', workspace.path, 'add']),
          ExitCodes.usage);
      expect(await run(['rule', '--profile', 'ai', '--owner', 'acme/api', 'add']), ExitCodes.usage);
      expect(await run(['rule', '--profile', 'nobody', '--owner', 'acme', 'add']), ExitCodes.usage);

      expect(await run(['rule', 'remove', 'acme']), ExitCodes.ok);
      expect(await run(['rule', 'remove', workspace.path]), ExitCodes.ok);
      expect(await run(['rule', 'remove', workspace.path]), ExitCodes.usage);
      expect(err.toString(), contains('There is no rule for'));
      expect(await RepoRuleRepository(paths: paths).getAll(), isEmpty);
      out.clear();
      expect(await run(['rule', 'list']), ExitCodes.ok);
      expect(out.toString(), contains('No rules yet'));
    });

    test('doctor --fix removes what points at deleted things', () async {
      await assignWorkspaceTo(aiProfile.copyWith(sshKeyId: 'deleted-key'));
      await RepoRuleRepository(paths: paths).upsert(
        RepoRule(id: 'orphan', pathPattern: '${workspace.path}/old', profileId: 'deleted-profile'),
      );

      await run(['doctor', '--json']);
      final before = lastJson();
      final categories = [for (final i in before['issues'] as List) i['category']];
      expect(categories, containsAll(['orphanedRuleProfile', 'orphanedSshKeyReference']));
      expect(before.containsKey('fixed'), isFalse);

      await run(['doctor', '--fix', '--json']);
      final after = lastJson();
      expect(after['fixed'], hasLength(2), reason: '$after');
      final left = [for (final i in after['issues'] as List) i['category']];
      expect(left, isNot(contains('orphanedRuleProfile')));
      expect(left, isNot(contains('orphanedSshKeyReference')));
      expect((await ProfileRepository(paths: paths).getAll()).single.sshKeyId, isNull);
      expect((await RepoRuleRepository(paths: paths).getAll()).map((r) => r.id), ['rule-1']);

      await run(['doctor', '--fix']);
      expect(out.toString(), isNot(contains('Fixed:')));
    });

    test("doctor --fix points a company's organization back at the work profile", () async {
      await assignWorkspaceTo(aiProfile);
      await run(['profile', '--name', 'Jane', '--email', 'jane@acme.com', '--label', 'Work', 'add']);
      final file = File('${home.path}/acme.gita.json')
        ..writeAsStringSync('{"name": "Acme", "emailDomains": ["acme.com"], "github": {"owners": ["acme"]}}');
      expect(await run(['company', 'import', file.path]), ExitCodes.ok, reason: '$out$err');
      // Someone points acme at the wrong profile.
      expect(await run(['rule', '--profile', 'ai', '--owner', 'acme', 'add']), ExitCodes.ok);
      out.clear();

      expect(await run(['doctor', '--json']), ExitCodes.problem);
      expect([for (final i in lastJson()['issues'] as List) i['category']], contains('companyEmailMismatch'));

      expect(await run(['doctor', '--fix']), ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains('Fixed: Projects from github.com/acme now use "Work" (jane@acme.com).'));
      final rule = (await RepoRuleRepository(paths: paths).getAll()).singleWhere((r) => r.isAccountRule);
      final work = (await ProfileRepository(paths: paths).getAll()).singleWhere((x) => x.label == 'Work');
      expect(rule.profileId, work.id);
    });

    test('setup adds a profile per account the projects use', () async {
      final projects = '${workspace.path}/Projects';
      await gitRepo('$projects/work/api', 'dev@acme.com');
      await gitRepo('$projects/mine/blog', 'me@gmail.com');

      expect(await run(['setup', projects]), ExitCodes.ok, reason: '$out$err');
      expect(out.toString(), contains('Set up 2 profile(s):'));
      expect(out.toString(), contains('<dev@acme.com>'));
      expect(out.toString(), contains('gita sign-in --profile'));
      expect(await ProfileRepository(paths: paths).getAll(), hasLength(2));

      // Running it again reuses the profiles.
      out.clear();
      expect(await run(['setup', '--json', projects]), ExitCodes.ok);
      expect(lastJson()['profiles'], hasLength(2));
      expect(await ProfileRepository(paths: paths).getAll(), hasLength(2));

      // A folder with no projects, and one that isn't there.
      final empty = Directory('${workspace.path}/empty')..createSync();
      expect(await run(['setup', empty.path]), ExitCodes.problem);
      expect(err.toString(), contains('gita profile add'));
      expect(await run(['setup', '${workspace.path}/missing']), ExitCodes.usage);
    });
  });
}
