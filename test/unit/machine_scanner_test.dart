import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/hook_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/legacy_tokens.dart';
import 'package:gita/core/services/machine_scanner.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/secure_token_service.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:path/path.dart' as p;

class _NoLegacyTokens implements LegacyTokens {
  @override
  Future<int> migrateAll(TokenStore store, Iterable<String> profileIds) async => 0;

  @override
  Future<void> forget(String profileId) async {}
}

const _palette = [0xFF000001, 0xFF000002, 0xFF000003];

void main() {
  group('helpers', () {
    test('sshHostOf reads the host of SSH remotes only', () {
      expect(sshHostOf('git@github.com:org/repo.git'), 'github.com');
      expect(sshHostOf('git@github-work:org/repo.git'), 'github-work');
      expect(sshHostOf('ssh://git@github.com/org/repo.git'), 'github.com');
      expect(sshHostOf('ssh://git@gh-work:22/org/repo.git'), 'gh-work');
      expect(sshHostOf('https://github.com/org/repo.git'), isNull);
      expect(sshHostOf('C:/local/repo'), isNull);
    });

    test('githubLoginFromEmail reads GitHub noreply emails', () {
      expect(githubLoginFromEmail('1234+octo-cat@users.noreply.github.com'), 'octo-cat');
      expect(githubLoginFromEmail('octo@users.noreply.github.com'), 'octo');
      expect(githubLoginFromEmail('octo@example.com'), isNull);
    });

    test('suggestLabel names personal mail "Personal" and companies by domain', () {
      expect(suggestLabel('me@gmail.com'), 'Personal');
      expect(suggestLabel('me@Outlook.com'), 'Personal');
      expect(suggestLabel('1+me@users.noreply.github.com'), 'Personal');
      expect(suggestLabel('naseeb@thoughtbox.io'), 'Thoughtbox');
      expect(suggestLabel('dev@mail.acme.co.uk'), 'Acme');
      expect(suggestLabel('dev@eng.bigcorp.com'), 'Bigcorp');
      expect(suggestLabel('weird'), 'Profile');
    });
  });

  group('suggest', () {
    ScannedRepo repo(String path, String? email, {List<String> remotes = const []}) =>
        ScannedRepo(path: path, localEmail: email, localName: 'N', remoteUrls: remotes);

    test('groups projects by email, global identity first, and picks folders', () {
      final repos = [
        repo('C:/Users/me/work/a', 'dev@acme.com'),
        repo('C:/Users/me/work/b', 'dev@acme.com'),
        repo('C:/Users/me/code/mine', 'me@gmail.com'),
        repo('C:/Users/me/code/acme-tool', 'dev@acme.com'),
        repo('C:/Users/me/code/unknown', null),
      ];
      final s = MachineScanner.suggest(
        repos: repos,
        globalEmail: 'me@gmail.com',
        globalName: 'Me',
        searchFolders: ['C:/Users/me/work', 'C:/Users/me/code'],
        homeDir: 'C:/Users/me',
      );

      expect(s.map((x) => x.email), ['me@gmail.com', 'dev@acme.com']);
      expect(s.first.isGlobalDefault, isTrue);
      expect(s.first.label, 'Personal');
      expect(s.first.name, 'Me', reason: 'the name in ~/.gitconfig wins for the global identity');
      expect(s[1].name, 'N');
      // code/ mixes accounts, so each project is listed on its own.
      expect(s.first.folders, ['C:/Users/me/code/mine']);
      final acme = s[1];
      expect(acme.label, 'Acme');
      // work/ is all Acme: the whole folder. acme-tool sits in mixed code/.
      expect(acme.folders, ['C:/Users/me/code/acme-tool', 'C:/Users/me/work']);
      expect(acme.repos, hasLength(3));
    });

    test('a lone project in a folder of its own gives that folder', () {
      final s = MachineScanner.suggest(
        repos: [
          repo('C:/Users/me/code/clients/bigco/app', 'dev@bigco.com'),
          repo('C:/Users/me/code/other', 'me@gmail.com'),
        ],
        searchFolders: ['C:/Users/me/code'],
        homeDir: 'C:/Users/me',
      );
      final bigco = s.firstWhere((x) => x.email == 'dev@bigco.com');
      expect(bigco.folders, ['C:/Users/me/code/clients/bigco']);
      // A lone project directly in a search folder stays just the project.
      final me = s.firstWhere((x) => x.email == 'me@gmail.com');
      expect(me.folders, ['C:/Users/me/code/other']);
    });

    test('never suggests the home folder or a drive', () {
      final s = MachineScanner.suggest(
        repos: [repo('C:/Users/me/proj', 'a@acme.com'), repo('C:/top', 'a@acme.com')],
        homeDir: 'C:/Users/me',
      );
      expect(s.single.folders, ['C:/Users/me/proj', 'C:/top']);
    });

    test('same email in different case is one identity', () {
      final s = MachineScanner.suggest(
        repos: [repo('C:/x/a/one', 'Dev@Acme.com'), repo('C:/x/b/two', 'dev@acme.com')],
        homeDir: 'C:/Users/me',
      );
      expect(s, hasLength(1));
      expect(s.single.repos, hasLength(2));
    });

    test('marks emails that already have a profile and keeps its name', () {
      final existing = Profile(
        id: 'p1',
        label: 'Job',
        gitName: 'Dev',
        gitEmail: 'dev@acme.com',
        colorArgb: 1,
        createdAt: DateTime(2026),
      );
      final s = MachineScanner.suggest(
        repos: [repo('C:/x/a/one', 'dev@acme.com'), repo('C:/x/b/two', 'me@acme.org')],
        existingProfiles: [existing],
        homeDir: 'C:/Users/me',
      );
      final known = s.firstWhere((x) => x.email == 'dev@acme.com');
      expect(known.existingProfileId, 'p1');
      expect(known.label, 'Job');
      // Labels don't repeat: acme.org would be "Acme" too.
      expect(s.firstWhere((x) => x.email == 'me@acme.org').label, 'Acme');
    });

    test('two companies with the same label get numbered', () {
      final s = MachineScanner.suggest(
        repos: [repo('C:/x/a/one', 'a@acme.com'), repo('C:/x/b/two', 'b@acme.org')],
        homeDir: 'C:/Users/me',
      );
      expect(s.map((x) => x.label).toSet(), {'Acme', 'Acme 2'});
    });

    test('matches SSH keys by host alias first, then by comment', () {
      const work = FoundSshKey(
          privateKeyPath: 'C:/Users/me/.ssh/id_work', publicKeyPath: 'C:/Users/me/.ssh/id_work.pub');
      const home = FoundSshKey(
          privateKeyPath: 'C:/Users/me/.ssh/id_home',
          publicKeyPath: 'C:/Users/me/.ssh/id_home.pub',
          comment: 'me@gmail.com');
      final s = MachineScanner.suggest(
        repos: [
          repo('C:/x/a/one', 'dev@acme.com', remotes: ['git@github-work:acme/one.git']),
          repo('C:/x/b/two', 'me@gmail.com', remotes: ['https://github.com/me/two']),
        ],
        keys: [work, home],
        sshAliases: {'github-work': 'C:/Users/me/.ssh/id_work'},
        homeDir: 'C:/Users/me',
      );
      expect(s.firstWhere((x) => x.email == 'dev@acme.com').sshKey, same(work));
      expect(s.firstWhere((x) => x.email == 'me@gmail.com').sshKey, same(home));
    });

    test('github login comes from a noreply email', () {
      final s = MachineScanner.suggest(
        repos: [repo('C:/x/a/one', '99+octo@users.noreply.github.com')],
        homeDir: 'C:/Users/me',
      );
      expect(s.single.githubLogin, 'octo');
      expect(s.single.label, 'Personal');
    });
  });

  group('SetupPlan.build', () {
    var n = 0;
    String id() => 'id${n++}';
    setUp(() => n = 0);

    test('makes profiles, keys and rules, skipping ones that exist', () {
      final existingProfile = Profile(
        id: 'old',
        label: 'Job',
        gitName: 'Dev',
        gitEmail: 'dev@acme.com',
        colorArgb: 1,
        createdAt: DateTime(2026),
      );
      final key = const FoundSshKey(privateKeyPath: '/h/.ssh/k', publicKeyPath: '/h/.ssh/k.pub');
      final plan = SetupPlan.build(
        choices: [
          SetupChoice(
            label: ' Personal ',
            name: 'Me',
            email: 'me@gmail.com',
            folders: ['C:/code/mine', 'C:/code/dup'],
            sshKey: key,
            githubLogin: 'me',
            projects: ['C:/code/mine'],
          ),
          SetupChoice(
            label: 'ignored',
            name: 'x',
            email: 'dev@acme.com',
            folders: ['C:/work'],
            sshKey: key,
            existingProfileId: 'old',
          ),
        ],
        existingKeys: const [],
        existingRules: const [RepoRule(id: 'r', pathPattern: 'C:/code/dup/', profileId: 'z')],
        existingProfiles: [existingProfile],
        palette: _palette,
        newId: id,
      );

      expect(plan.sshKeys, hasLength(1), reason: 'the same key is imported once');
      final personal = plan.profiles.first;
      expect(personal.label, 'Personal');
      expect(personal.gitEmail, 'me@gmail.com');
      expect(personal.sshKeyId, plan.sshKeys.single.id);
      expect(personal.githubLogin, 'me');
      expect(personal.colorArgb, _palette[1], reason: 'next colour after the existing profile');
      final job = plan.profiles[1];
      expect(job.id, 'old');
      expect(job.label, 'Job');
      expect(job.sshKeyId, plan.sshKeys.single.id);
      expect(plan.rules.map((r) => r.pathPattern), ['C:/code/mine', 'C:/work']);
      expect(plan.rules.last.profileId, 'old');
      expect(plan.projects, ['C:/code/mine']);
    });
  });

  group('on a real (temp) computer', () {
    late Directory home;
    late PlatformPaths paths;
    late GitService git;
    late ProviderContainer container;

    Future<void> gitIn(String dir, List<String> args) async {
      final r = await git.raw(args, workingDir: dir);
      expect(r.exitCode, 0, reason: '${args.join(' ')}: ${r.stderr}');
    }

    Future<String> makeRepo(String rel, {String? localEmail, String? commitEmail, String? remote}) async {
      final dir = Directory(p.join(home.path, rel))..createSync(recursive: true);
      await gitIn(dir.path, ['init', '-q']);
      if (localEmail != null) {
        await gitIn(dir.path, ['config', 'user.email', localEmail]);
        await gitIn(dir.path, ['config', 'user.name', 'Local Name']);
      }
      if (commitEmail != null) {
        File(p.join(dir.path, 'f.txt')).writeAsStringSync('x');
        await gitIn(dir.path, ['add', '.']);
        await gitIn(dir.path, [
          '-c', 'user.email=$commitEmail', '-c', 'user.name=Committer', //
          '-c', 'core.hooksPath=', 'commit', '-q', '-m', 'one',
        ]);
      }
      if (remote != null) await gitIn(dir.path, ['remote', 'add', 'origin', remote]);
      return resolveRepoPath(dir.path);
    }

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_scan_home_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      git = GitService(environmentOverride: {
        'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
        'GIT_CONFIG_SYSTEM': p.join(home.path, 'gitconfig_system'),
      });
      File(paths.gitConfigPath).writeAsStringSync('[user]\n  name = Global Me\n  email = me@gmail.com\n');
      container = ProviderContainer(overrides: [
        platformPathsProvider.overrideWithValue(paths),
        gitServiceProvider.overrideWithValue(git),
        secureTokenServiceProvider.overrideWithValue(SecureTokenService(
          store: TokenStore(keychain: InMemoryKeychainStore()),
          legacy: _NoLegacyTokens(),
        )),
      ]);
    });

    tearDown(() async {
      container.dispose();
      if (home.existsSync()) await home.delete(recursive: true);
    });

    test('finds projects, their emails, SSH keys and suggests profiles', () async {
      final a = await makeRepo('work/acme/api',
          localEmail: 'dev@acme.com', remote: 'git@github-acme:acme/api.git');
      final b = await makeRepo('work/acme/web', commitEmail: 'dev@acme.com');
      final mine = await makeRepo('projects/hobby', commitEmail: 'me@gmail.com');
      await makeRepo('projects/fresh'); // no commits, no email
      // Things the scan must skip.
      await makeRepo('projects/app/node_modules/dep', localEmail: 'x@dep.com');
      await makeRepo('.hidden/secret', localEmail: 'x@hidden.com');
      await makeRepo('projects/hobby/sub', localEmail: 'x@nested.com');

      final ssh = Directory(p.join(home.path, '.ssh'))..createSync();
      File(p.join(ssh.path, 'id_acme')).writeAsStringSync('private');
      File(p.join(ssh.path, 'id_acme.pub')).writeAsStringSync('ssh-ed25519 AAAA laptop');
      File(p.join(ssh.path, 'id_me')).writeAsStringSync('private');
      File(p.join(ssh.path, 'id_me.pub')).writeAsStringSync('ssh-ed25519 BBBB me@gmail.com\n');
      File(p.join(ssh.path, 'lonely.pub')).writeAsStringSync('ssh-ed25519 CCCC');
      File(p.join(ssh.path, 'config')).writeAsStringSync(
        'Host github-acme\n  HostName github.com\n  IdentityFile ~/.ssh/id_acme\n',
      );

      final scanner = container.read(machineScannerProvider);
      expect(scanner.defaultSearchFolders().map(p.posix.basename).toSet(), {'work', 'projects'});

      final scan = await scanner.scan();

      expect(scan.globalEmail, 'me@gmail.com');
      expect(scan.globalName, 'Global Me');
      expect(scan.repos.map((r) => r.path).toSet(),
          {a, b, mine, resolveRepoPath(p.join(home.path, 'projects', 'fresh'))});
      expect(scan.repos.firstWhere((r) => r.path == b).usedEmail, 'dev@acme.com');
      expect(scan.repos.firstWhere((r) => r.path == a).remoteUrls, ['git@github-acme:acme/api.git']);
      expect(scan.unknownRepos.single.path, endsWith('projects/fresh'));
      expect(scan.sshKeys.map((k) => k.fileName), ['id_acme', 'id_me']);

      final me = scan.suggestions.first;
      expect(me.email, 'me@gmail.com');
      expect(me.isGlobalDefault, isTrue);
      expect(me.sshKey?.fileName, 'id_me');
      expect(me.folders, [mine]);
      final acme = scan.suggestions[1];
      expect(acme.label, 'Acme');
      expect(acme.sshKey?.fileName, 'id_acme');
      expect(acme.folders, [p.posix.dirname(a)]);

      final json = scan.toJson();
      expect((json['profiles'] as List), hasLength(2));
    });

    test('apply saves everything, writes git settings and adds safety checks', () async {
      final api = await makeRepo('work/acme/api', localEmail: 'dev@acme.com');
      await makeRepo('work/acme/web', commitEmail: 'dev@acme.com');
      final mine = await makeRepo('projects/hobby', commitEmail: 'me@gmail.com');
      final actions = container.read(setupActionsProvider);
      expect(await actions.shouldOfferSetup(), isTrue);

      final scan = await container.read(machineScannerProvider).scan();
      final result = await actions.apply(
        [for (final s in scan.suggestions) SetupChoice.from(s)],
        palette: _palette,
      );

      expect(result.newProfiles, 2);
      expect(result.rules, 2);
      expect(result.projects, 3);
      final profiles = await ProfileRepository(paths: paths).getAll();
      expect(profiles.map((x) => x.gitEmail).toSet(), {'me@gmail.com', 'dev@acme.com'});
      expect(await container.read(profilesProvider.future), hasLength(2));

      // Git now gives the right email in a project whose commits had it.
      final web = resolveRepoPath(p.join(home.path, 'work', 'acme', 'web'));
      expect(await git.getConfigValue(web, 'user.email'), 'dev@acme.com');
      expect(await git.getConfigValue(mine, 'user.email'), 'me@gmail.com');
      // Safety checks went in.
      final hooks = HookService(paths: paths, git: git);
      expect((await hooks.status(api)).state, GuardState.installed);
      expect((await TrackedRepoRepository(paths: paths).getAll()), hasLength(3));

      // It won't open by itself again, and a second run adds nothing new.
      expect(await actions.shouldOfferSetup(), isFalse);
      final again = await container.read(machineScannerProvider).scan(existingProfiles: profiles);
      expect(again.suggestions.every((s) => s.existingProfileId != null), isTrue);
      final second = await actions.apply(
        [for (final s in again.suggestions) SetupChoice.from(s)],
        palette: _palette,
        trackProjects: false,
      );
      expect(second.newProfiles, 0);
      expect(second.rules, 0);
      expect(await ProfileRepository(paths: paths).getAll(), hasLength(2));
      expect(await RepoRuleRepository(paths: paths).getAll(), hasLength(2));
    });

    test('a computer with no projects still suggests the global identity', () async {
      final scan = await container.read(machineScannerProvider).scan();
      expect(scan.repos, isEmpty);
      expect(scan.suggestions.single.email, 'me@gmail.com');
      expect(scan.suggestions.single.folders, isEmpty);
    });

    test('skipping setup is remembered', () async {
      final actions = container.read(setupActionsProvider);
      await actions.markSetupDone();
      expect(await actions.shouldOfferSetup(), isFalse);
    });
  });
}
