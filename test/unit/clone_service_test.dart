import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/clone_service.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/hook_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:path/path.dart' as p;

Profile _profile(String id, String label, String email, {String? login, String? sshKeyId}) => Profile(
      id: id,
      label: label,
      gitName: label,
      gitEmail: email,
      githubLogin: login,
      sshKeyId: sshKeyId,
      colorArgb: 0xFF112233,
      createdAt: DateTime(2026),
    );

final _work = _profile('work', 'Work', 'dev@acme.com', login: 'acme-dev');
final _personal = _profile('me', 'Personal', 'me@gmail.com', login: 'MeOnGitHub');

void main() {
  group('address helpers', () {
    test('recognises the addresses people copy from GitHub', () {
      for (final ok in [
        'https://github.com/acme/api.git',
        'https://github.com/acme/api',
        'git@github.com:acme/api.git',
        'ssh://git@github.com/acme/api.git',
        'git@github.com-work:acme/api.git',
        'file:///C:/repos/api.git',
        '  https://github.com/acme/api.git  ',
      ]) {
        expect(CloneService.looksLikeGitUrl(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '',
        'acme/api',
        'github.com/acme/api',
        'https://github.com/',
        'hello world',
        'ftp://example.com/x',
      ]) {
        expect(CloneService.looksLikeGitUrl(bad), isFalse, reason: bad);
      }
    });

    test('works out the folder name and the owner', () {
      expect(CloneService.repoNameFromUrl('https://github.com/acme/api.git'), 'api');
      expect(CloneService.repoNameFromUrl('git@github.com:acme/web-app.GIT'), 'web-app');
      expect(CloneService.repoNameFromUrl('https://github.com/acme/api/'), 'api');
      expect(CloneService.repoNameFromUrl('file:///C:/repos/tool.git'), 'tool');
      expect(CloneService.ownerFromUrl('https://github.com/acme/api.git'), 'acme');
      expect(CloneService.ownerFromUrl('git@github.com:Acme/api.git'), 'Acme');
      expect(CloneService.ownerFromUrl('https://github.com/api'), isNull);
      expect(CloneService.isSshUrl('git@github.com:acme/api.git'), isTrue);
      expect(CloneService.isSshUrl('ssh://git@github.com/acme/api'), isTrue);
      expect(CloneService.isSshUrl('https://github.com/acme/api'), isFalse);
    });

    test('suggests the profile whose GitHub account owns the project', () {
      final profiles = [_work, _personal];
      expect(CloneService.suggestProfile('https://github.com/acme-dev/api', profiles)?.id, 'work');
      expect(CloneService.suggestProfile('git@github.com:meongithub/blog.git', profiles)?.id, 'me');
      expect(CloneService.suggestProfile('https://github.com/someone-else/x', profiles), isNull);
      expect(CloneService.suggestProfile('not an address', profiles), isNull);
    });
  });

  group('explainCloneError', () {
    String explain(String stderr, {bool signedIn = true, Profile? profile}) =>
        CloneService.explainCloneError(stderr,
            profile: profile ?? _work, url: 'https://github.com/acme/api', signedIn: signedIn);

    test('turns git errors into what to do', () {
      expect(explain('git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.'),
          contains('SSH key'));
      expect(explain('remote: Repository not found.\nfatal: repository not found'),
          allOf(contains("can't see it"), contains('@acme-dev')));
      expect(explain('remote: Repository not found.', signedIn: false), contains('not signed in'));
      expect(explain('fatal: could not read Username for \'https://github.com\': terminal prompts disabled',
              signedIn: false),
          allOf(contains('Work is not signed in'), contains('check the address')));
      expect(explain('fatal: Authentication failed for ...'), contains('refused'));
      expect(explain('fatal: unable to access ...: Could not resolve host: github.com'),
          contains('internet connection'));
      expect(explain("fatal: destination path 'api' already exists and is not an empty directory."),
          contains('already a folder'));
      expect(explain("fatal: '/x/y' does not appear to be a git repository"), contains('green Code button'));
    });

    test('falls back to git\'s last line', () {
      expect(explain("Cloning into 'api'...\nerror: something odd\nfatal: early EOF"),
          "The clone didn't work: fatal: early EOF");
      expect(explain(''), "The clone didn't work: git gave no reason");
    });
  });

  group('clone (real git, temp home)', () {
    late Directory home;
    late PlatformPaths paths;
    late GitService git;
    late String origin;
    late String originUrl;

    Future<void> ok(List<String> args, String dir) async {
      final r = await git.raw(args, workingDir: dir);
      expect(r.exitCode, 0, reason: '${args.join(' ')}: ${r.stderr}');
    }

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_clone_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      git = GitService(environmentOverride: {
        'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
        'GIT_CONFIG_SYSTEM': p.join(home.path, 'gitconfig_system'),
      });
      File(paths.gitConfigPath).writeAsStringSync('[user]\n  name = Global\n  email = global@example.com\n');

      // A small project to clone from.
      final src = Directory(p.join(home.path, 'src'))..createSync();
      await ok(['init', '-q'], src.path);
      File(p.join(src.path, 'README.md')).writeAsStringSync('hi\n');
      await ok(['add', '.'], src.path);
      await ok(['-c', 'user.name=A', '-c', 'user.email=a@b.c', 'commit', '-q', '-m', 'first'], src.path);
      origin = p.join(home.path, 'api.git');
      await ok(['clone', '-q', '--bare', src.path, origin], home.path);
      originUrl = Uri.file(origin).toString();

      await ProfileRepository(paths: paths).upsert(_work);
      await ProfileRepository(paths: paths).upsert(_personal);
    });

    tearDown(() async {
      for (var i = 0; i < 10 && home.existsSync(); i++) {
        try {
          await home.delete(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    });

    Future<String?> email(String repo) => git.getConfigValue(repo, 'user.email');

    test('clones as the profile, adds a rule, the safety check and a Dashboard entry', () async {
      final service = CloneService(paths: paths, git: git);
      final dest = resolveRepoPath(p.join(home.path, 'code', 'api'));
      final progress = <String>[];
      final outcome = await service.clone(
        url: originUrl,
        destination: dest,
        profile: _work,
        hasToken: (_) async => false,
        onProgress: progress.add,
      );
      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.path, dest);
      expect(outcome.addedRule, isTrue);
      expect(outcome.guardAdded, isTrue);
      expect(outcome.message, contains('Work <dev@acme.com>'));
      expect(progress, isNotEmpty);
      expect(File(p.join(dest, 'README.md')).existsSync(), isTrue);

      // The project now uses the work identity on its own.
      expect(await email(dest), 'dev@acme.com');
      final rules = await RepoRuleRepository(paths: paths).getAll();
      expect(RepoRule.bestMatchFor(dest, rules)?.profileId, 'work');
      expect((await HookService(paths: paths, git: git).status(dest)).state, GuardState.installed);
      final tracked = await TrackedRepoRepository(paths: paths).getAll();
      expect(tracked.map((t) => t.path), [dest]);
      expect(tracked.single.hookInstalled, isTrue);
    });

    test('keeps the existing folder rule when it already points at the profile', () async {
      final parent = resolveRepoPath(p.join(home.path, 'work'));
      Directory(parent).createSync();
      await RepoRuleRepository(paths: paths)
          .upsert(RepoRule(id: 'r1', pathPattern: parent, profileId: 'work'));
      final service = CloneService(paths: paths, git: git);
      expect(service.parentFolderFor(_work, await RepoRuleRepository(paths: paths).getAll()), parent);

      final outcome = await service.clone(
        url: originUrl,
        destination: '$parent/api',
        profile: _work,
        hasToken: (_) async => false,
        track: false,
      );
      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.addedRule, isFalse);
      expect(outcome.guardAdded, isFalse);
      expect(await RepoRuleRepository(paths: paths).getAll(), hasLength(1));
      expect(await TrackedRepoRepository(paths: paths).getAll(), isEmpty);
      expect(await email('$parent/api'), 'dev@acme.com');
    });

    test('overrides a folder rule for another profile with an exact one', () async {
      final parent = resolveRepoPath(p.join(home.path, 'mixed'));
      Directory(parent).createSync();
      await RepoRuleRepository(paths: paths)
          .upsert(RepoRule(id: 'r1', pathPattern: parent, profileId: 'work'));
      final outcome = await CloneService(paths: paths, git: git).clone(
        url: originUrl,
        destination: '$parent/blog',
        profile: _personal,
        hasToken: (_) async => false,
        track: false,
      );
      expect(outcome.ok, isTrue, reason: outcome.message);
      expect(outcome.addedRule, isTrue);
      expect(await email('$parent/blog'), 'me@gmail.com');
    });

    test('refuses a folder that already has files and explains a bad address', () async {
      final dest = Directory(p.join(home.path, 'busy'))..createSync();
      File(p.join(dest.path, 'x.txt')).writeAsStringSync('x');
      final service = CloneService(paths: paths, git: git);
      final busy = await service.clone(
        url: originUrl,
        destination: dest.path,
        profile: _work,
        hasToken: (_) async => false,
      );
      expect(busy.ok, isFalse);
      expect(busy.message, contains('already a folder'));

      final missing = await service.clone(
        url: Uri.file(p.join(home.path, 'nope.git')).toString(),
        destination: p.join(home.path, 'nope'),
        profile: _work,
        hasToken: (_) async => false,
      );
      expect(missing.ok, isFalse);
      expect(missing.message, isNot(startsWith("The clone didn't work: Cloning")));
      expect(await RepoRuleRepository(paths: paths).getAll(), isEmpty);
      expect(await TrackedRepoRepository(paths: paths).getAll(), isEmpty);
    });

    group('gita clone', () {
      late StringBuffer out;
      late StringBuffer err;

      Future<int> run(List<String> args) => GitaCli(
            out: out,
            err: err,
            paths: paths,
            gitService: git,
            cwd: home.path,
            tokenStore: TokenStore(keychain: InMemoryKeychainStore()),
          ).run(args);

      setUp(() {
        out = StringBuffer();
        err = StringBuffer();
      });

      test('clones into the given folder with --profile', () async {
        final code = await run(['clone', originUrl, 'here/api', '--profile', 'Personal']);
        expect(code, ExitCodes.ok, reason: '$out\n$err');
        final dest = resolveRepoPath(p.join(home.path, 'here', 'api'));
        expect(out.toString(), contains('Cloning as Personal <me@gmail.com> into $dest ...'));
        expect(out.toString(), contains('Added a rule'));
        expect(out.toString(), contains('Added the safety check'));
        expect(await email(dest), 'me@gmail.com');
      });

      test('--json reports the outcome, --no-track leaves the Dashboard alone', () async {
        final code = await run(['clone', originUrl, 'j/api', '--profile', 'work', '--no-track', '--json']);
        expect(code, ExitCodes.ok, reason: '$out\n$err');
        final json = jsonDecode(out.toString()) as Map<String, dynamic>;
        expect(json['ok'], isTrue);
        expect(json['profile'], 'work');
        expect(json['safetyCheck'], isFalse);
        expect(json['path'], resolveRepoPath(p.join(home.path, 'j', 'api')));
        expect(await TrackedRepoRepository(paths: paths).getAll(), isEmpty);
      });

      test('uses the folder rule\'s profile when no --profile is given', () async {
        final parent = resolveRepoPath(p.join(home.path, 'acme'));
        Directory(parent).createSync();
        await RepoRuleRepository(paths: paths)
            .upsert(RepoRule(id: 'r1', pathPattern: parent, profileId: 'work'));
        final code = await run(['clone', originUrl, 'acme/api']);
        expect(code, ExitCodes.ok, reason: '$out\n$err');
        expect(out.toString(), contains('Cloning as Work'));
        expect(out.toString(), isNot(contains('Added a rule')));
      });

      test('asks for --profile when it cannot tell, and explains bad input', () async {
        expect(await run(['clone', originUrl]), ExitCodes.usage);
        expect(err.toString(), contains('--profile'));

        err.clear();
        expect(await run(['clone']), ExitCodes.usage);
        expect(err.toString(), contains('Say what to clone'));

        err.clear();
        expect(await run(['clone', 'acme/api']), ExitCodes.usage);
        expect(err.toString(), contains("doesn't look like a project address"));

        err.clear();
        expect(await run(['clone', originUrl, '--profile', 'nobody']), ExitCodes.usage);
        expect(err.toString(), contains('There is no profile called "nobody"'));
      });

      test('fails with a plain message when git fails', () async {
        final code = await run(['clone', Uri.file(p.join(home.path, 'gone.git')).toString(), 'gone', '--profile', 'work']);
        expect(code, ExitCodes.problem);
        expect(err.toString(), isNotEmpty);
        expect(Directory(p.join(home.path, 'gone')).existsSync(), isFalse);
      });
    });
  });
}
