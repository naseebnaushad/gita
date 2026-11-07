import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/doctor_issue.dart';
import 'package:gita/core/models/mismatch_report.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/clone_service.dart';
import 'package:gita/core/services/company_setup.dart';
import 'package:gita/core/services/doctor_fixes.dart';
import 'package:gita/core/services/git_config_sync.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/gitconfig_service.dart';
import 'package:gita/core/services/identity_doctor_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/remote_url.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:gita/features/rules/rules_screen.dart';

Profile _profile(String id, String label, String email, {String? login}) =>
    Profile(
      id: id,
      label: label,
      gitName: '$label Name',
      gitEmail: email,
      githubLogin: login,
      colorArgb: 0xFF112233,
      createdAt: DateTime(2026),
    );

final _work = _profile('work', 'Work', 'dev@acme.com', login: 'acme-dev');
final _personal = _profile(
  'me',
  'Personal',
  'me@gmail.com',
  login: 'MeOnGitHub',
);

const _acmeJson =
    '{"name": "Acme", "emailDomains": ["@Acme.com"], '
    '"github": {"owners": ["acme", "acme-labs"]}}';

void main() {
  group('RemoteUrl', () {
    test('reads host and owner from every address form', () {
      for (final (url, host, top) in [
        ('https://github.com/acme/api.git', 'github.com', 'acme'),
        ('https://user@GitHub.com/acme/api', 'github.com', 'acme'),
        ('git@github.com:acme/api.git', 'github.com', 'acme'),
        ('ssh://git@github.com/acme/api.git', 'github.com', 'acme'),
        ('ssh://git@github.com:22/acme/api.git', 'github.com', 'acme'),
        (
          'https://ghe.corp.example/team/sub/api.git',
          'ghe.corp.example',
          'team',
        ),
        ('git@github.com-work:acme/api.git', 'github.com-work', 'acme'),
      ]) {
        final r = RemoteUrl.parse(url);
        expect(r, isNotNull, reason: url);
        expect(r!.host, host, reason: url);
        expect(r.topOwner, top, reason: url);
      }
      expect(
        RemoteUrl.parse('https://ghe.corp.example/team/sub/api.git')!.owner,
        'sub',
      );
      expect(RemoteUrl.parse(''), isNull);
      expect(RemoteUrl.parse('just-words'), isNull);
      expect(RemoteUrl.parse('C:/repos/api'), isNull);
      expect(RemoteUrl.parse('https://github.com/api')!.topOwner, isNull);
    });
  });

  group('account rules', () {
    final acme = RepoRule.account(id: 'a', owner: 'Acme', profileId: 'work');

    test('cover remotes on the same host and owner, in any case', () {
      expect(acme.isAccountRule, isTrue);
      expect(acme.describe, 'github.com/Acme');
      expect(acme.coversRemote('https://github.com/acme/api.git'), isTrue);
      expect(acme.coversRemote('git@github.com:ACME/api.git'), isTrue);
      expect(acme.coversRemote('ssh://git@github.com/acme/api'), isTrue);
      expect(
        acme.coversRemote('https://x-access-token@github.com/acme/api'),
        isTrue,
      );
      expect(
        acme.coversRemote('https://github.com/acme-labs/api.git'),
        isFalse,
      );
      expect(acme.coversRemote('https://gitlab.com/acme/api.git'), isFalse);
      expect(acme.coversRemote('https://github.com/someone/acme.git'), isFalse);
      expect(
        RepoRule(
          id: 'f',
          pathPattern: 'C:/x',
          profileId: 'p',
        ).coversRemote('https://github.com/acme/a'),
        isFalse,
      );
    });

    test('survive a JSON round trip; old rules still load', () {
      final ghe = RepoRule.account(
        id: 'b',
        owner: 'team',
        profileId: 'p',
        host: ' GHE.Corp.Example ',
      );
      expect(ghe.host, 'ghe.corp.example');
      for (final r in [acme, ghe]) {
        final back = RepoRule.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
        );
        expect(back.githubOwner, r.githubOwner);
        expect(back.host, r.host);
        expect(back.pathPattern, '');
        expect(back.isAccountRule, isTrue);
      }
      expect(acme.toJson().containsKey('host'), isFalse);
      final old = RepoRule.fromJson({
        'id': 'o',
        'pathPattern': 'C:/work',
        'profileId': 'p',
      });
      expect(old.isAccountRule, isFalse);
      expect(old.host, RepoRule.defaultHost);
      expect(old.toJson().containsKey('githubOwner'), isFalse);
    });

    test(
      'emit order: folders by length, then accounts by owner, then single projects',
      () async {
        final tmp = await Directory.systemTemp.createTemp('gita_emit_');
        addTearDown(() => tmp.delete(recursive: true));
        final project = Directory('${tmp.path}/proj')..createSync();
        Directory('${project.path}/.git').createSync();
        final rules = [
          RepoRule(id: 'proj', pathPattern: project.path, profileId: 'p'),
          RepoRule.account(id: 'z', owner: 'zeta', profileId: 'p'),
          RepoRule(id: 'long', pathPattern: '${tmp.path}/a/b', profileId: 'p'),
          RepoRule.account(id: 'b', owner: 'Beta', profileId: 'p'),
          RepoRule(id: 'short', pathPattern: '${tmp.path}/a', profileId: 'p'),
          const RepoRule(id: 'empty', pathPattern: '', profileId: 'p'),
        ];
        expect(RepoRule.inEmitOrder(rules).map((r) => r.id), [
          'short',
          'long',
          'b',
          'z',
          'proj',
        ]);
      },
    );

    test('bestMatchFor: exact project beats account beats folder', () async {
      final tmp = await Directory.systemTemp.createTemp('gita_best_');
      addTearDown(() => tmp.delete(recursive: true));
      final folder = RepoRule(
        id: 'folder',
        pathPattern: '${tmp.path}/personal',
        profileId: 'me',
      );
      final account = RepoRule.account(
        id: 'acct',
        owner: 'acme',
        profileId: 'work',
      );
      final rules = [folder, account];
      final repo = '${tmp.path}/personal/api';
      const acmeUrl = ['https://github.com/acme/api.git'];

      expect(RepoRule.bestMatchFor(repo, rules)?.id, 'folder');
      expect(
        RepoRule.bestMatchFor(repo, rules, remoteUrls: acmeUrl)?.id,
        'acct',
      );
      expect(
        RepoRule.bestMatchFor(
          repo,
          rules,
          remoteUrls: ['https://github.com/other/x'],
        )?.id,
        'folder',
      );
      expect(
        RepoRule.bestMatchFor(
          '${tmp.path}/elsewhere/api',
          rules,
          remoteUrls: acmeUrl,
        )?.id,
        'acct',
      );
      expect(RepoRule.bestMatchFor('${tmp.path}/elsewhere/api', rules), isNull);

      final exact = RepoRule(
        id: 'exact',
        pathPattern: repo.toUpperCase(),
        profileId: 'me',
      );
      expect(
        RepoRule.bestMatchFor(repo, [...rules, exact], remoteUrls: acmeUrl)?.id,
        'exact',
      );

      // Two accounts both match (two remotes): the one git applies last wins.
      final labs = RepoRule.account(
        id: 'labs',
        owner: 'acme-labs',
        profileId: 'me',
      );
      expect(
        RepoRule.bestMatchFor(
          repo,
          [account, labs],
          remoteUrls: [
            'https://github.com/acme/a',
            'https://github.com/acme-labs/a',
          ],
        )?.id,
        'labs',
      );
    });
  });

  group('gitconfig for account rules', () {
    test(
      'patterns cover HTTPS, HTTPS with a user, SSH and ssh://, any case',
      () {
        expect(GitConfigService.anyCase('Ab-1.x_'), '[aA][bB]-1.[xX]_');
        const h = '[gG][iI][tT][hH][uU][bB].[cC][oO][mM]';
        const o = '[aA][cC][mM][eE]';
        expect(
          GitConfigService.accountRemotePatterns(
            RepoRule.account(id: 'a', owner: 'Acme', profileId: 'w'),
          ),
          [
            'https://$h/$o/**',
            'https://*@$h/$o/**',
            '*@$h:$o/**',
            'ssh://*@$h/$o/**',
            'ssh://*@$h:*/$o/**',
          ],
        );
      },
    );

    test(
      'real git picks the identity from the remote, wherever the folder is',
      () async {
        final home = await Directory.systemTemp.createTemp('gita_org_home_');
        final ws = await Directory.systemTemp.createTemp('gita_org_ws_');
        addTearDown(() async {
          await home.delete(recursive: true);
          await ws.delete(recursive: true);
        });
        final paths = PlatformPaths(overrideHomeDir: home.path);
        final git = GitService(
          environmentOverride: {
            'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
            'GIT_CONFIG_SYSTEM': '${home.path}/nosystem',
          },
        );
        final personalDir = Directory('${ws.path}/personal')..createSync();
        await ProfileRepository(paths: paths).upsert(_work);
        await ProfileRepository(paths: paths).upsert(_personal);
        final rules = [
          RepoRule(
            id: 'f',
            pathPattern: resolveRepoPath(personalDir.path),
            profileId: 'me',
          ),
          RepoRule.account(id: 'acct', owner: 'Acme', profileId: 'work'),
        ];
        for (final r in rules) {
          await RepoRuleRepository(paths: paths).upsert(r);
        }
        await syncGitConfig(paths: paths, hasToken: (_) async => false);

        Future<String> repo(String name, String? remote) async {
          final dir = Directory('${personalDir.path}/$name')..createSync();
          await git.raw(['init', '-q'], workingDir: dir.path);
          if (remote != null) {
            await git.raw(['remote', 'add', 'origin', remote], workingDir: dir.path);
          }
          return resolveRepoPath(dir.path);
        }

        final cases = {
          await repo('https', 'https://github.com/acme/api.git'):
              'dev@acme.com',
          await repo('https-user', 'https://someone@github.com/ACME/api'):
              'dev@acme.com',
          await repo('ssh', 'git@github.com:acme/api.git'): 'dev@acme.com',
          await repo('sshurl', 'ssh://git@github.com/Acme/api.git'):
              'dev@acme.com',
          await repo('sshport', 'ssh://git@github.com:22/acme/api.git'):
              'dev@acme.com',
          await repo('upper', 'git@GitHub.com:ACME/api.git'): 'dev@acme.com',
          await repo('lookalike', 'https://github.com/acme-labs/api.git'):
              'me@gmail.com',
          await repo('other', 'https://github.com/meongithub/blog.git'):
              'me@gmail.com',
          await repo('noremote', null): 'me@gmail.com',
        };
        final loaded = await RepoRuleRepository(paths: paths).getAll();
        for (final MapEntry(key: path, value: email) in cases.entries) {
          expect(
            await git.getConfigValue(path, 'user.email'),
            email,
            reason: path,
          );
          // Gita's own resolver must agree with git.
          final rule = await git.ruleFor(path, loaded);
          expect(
            rule?.profileId,
            email == 'dev@acme.com' ? 'work' : 'me',
            reason: path,
          );
        }

        // A project outside any folder rule still gets the work identity.
        final outside = Directory('${ws.path}/loose')..createSync();
        await git.raw(['init', '-q'], workingDir: outside.path);
        await git.raw([
          'remote',
          'add',
          'upstream',
          'git@github.com:acme/tool.git',
        ], workingDir: outside.path);
        expect(
          await git.getConfigValue(outside.path, 'user.email'),
          'dev@acme.com',
        );
        expect(await git.remoteUrls(outside.path), [
          'git@github.com:acme/tool.git',
        ]);
      },
    );
  });

  group('CompanySetup', () {
    test('parses and normalises the file', () {
      final s = CompanySetup.parse(_acmeJson);
      expect(s.name, 'Acme');
      expect(s.emailDomains, ['acme.com']);
      expect(s.owners, ['acme', 'acme-labs']);
      expect(s.host, 'github.com');
      expect(CompanySetup.parse(jsonEncode(s.toJson())).owners, s.owners);
      expect(s.isCompanyEmail('Dev@ACME.com'), isTrue);
      expect(s.isCompanyEmail('dev@eu.acme.com'), isTrue);
      expect(s.isCompanyEmail('dev@notacme.com'), isFalse);
      expect(s.isCompanyEmail('nope'), isFalse);
      expect(s.companyProfiles([_work, _personal]).map((p) => p.id), ['work']);
    });

    test('says plainly what is wrong with a bad file', () {
      for (final (text, says) in [
        ('not json', 'should be JSON'),
        ('[1,2]', 'one JSON object'),
        ('{"github": {"owners": ["a"]}}', 'needs a "name"'),
        ('{"name": "Acme"}', 'GitHub organizations'),
        ('{"name": "Acme", "github": {"owners": []}}', 'GitHub organizations'),
      ]) {
        expect(
          () => CompanySetup.parse(text),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(says),
            ),
          ),
          reason: text,
        );
      }
    });

    test(
      'pickProfile only picks when exactly one profile has a company email',
      () {
        final s = CompanySetup.parse(_acmeJson);
        expect(CompanyService.pickProfile(s, [_work, _personal])?.id, 'work');
        expect(CompanyService.pickProfile(s, [_personal]), isNull);
        final work2 = _profile('w2', 'Work 2', 'other@acme.com');
        expect(CompanyService.pickProfile(s, [_work, work2]), isNull);
      },
    );
  });

  group('CompanyService.import', () {
    late Directory home;
    late PlatformPaths paths;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_company_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      await ProfileRepository(paths: paths).upsert(_work);
      await ProfileRepository(paths: paths).upsert(_personal);
    });
    tearDown(() => home.delete(recursive: true));

    test('adds, moves and leaves alone, and remembers the setup', () async {
      final service = CompanyService(paths: paths);
      final setup = CompanySetup.parse(_acmeJson);
      await RepoRuleRepository(
        paths: paths,
      ).upsert(RepoRule.account(id: 'old', owner: 'ACME', profileId: 'me'));

      final first = await service.import(
        setup,
        _work,
        hasToken: (_) async => false,
      );
      expect(first.added, ['acme-labs']);
      expect(first.moved, ['acme']);
      expect(first.unchanged, isEmpty);
      expect(first.message(setup), contains('now use "Work"'));

      final rules = await RepoRuleRepository(paths: paths).getAll();
      expect(rules, hasLength(2));
      expect(
        rules.firstWhere((r) => r.githubOwner == 'ACME').id,
        'old',
        reason: 'keeps the rule id',
      );
      expect(rules.every((r) => r.profileId == 'work'), isTrue);
      final gitconfig = File(paths.gitConfigPath).readAsStringSync();
      expect(
        gitconfig,
        contains('[includeIf "hasconfig:remote.*.url:https://'),
      );
      expect(gitconfig, contains('/[aA][cC][mM][eE]-[lL][aA][bB][sS]/**"]'));

      final again = await service.import(
        setup,
        _work,
        hasToken: (_) async => false,
      );
      expect(again.added, isEmpty);
      expect(again.moved, isEmpty);
      expect(again.unchanged, ['acme', 'acme-labs']);
      expect(again.message(setup), startsWith('Already set up'));

      // Re-importing a changed file with the same name replaces it.
      await service.import(
        CompanySetup.parse('{"name": "ACME", "github": {"owners": ["acme"]}}'),
        _work,
        hasToken: (_) async => false,
      );
      final saved = await service.load();
      expect(saved, hasLength(1));
      expect(saved.single.name, 'ACME');
      await service.import(
        CompanySetup.parse(
          '{"name": "Other", "github": {"owners": ["other"]}}',
        ),
        _personal,
        hasToken: (_) async => false,
      );
      expect((await service.load()).map((s) => s.name), ['ACME', 'Other']);
    });

    test('a broken company.json reads as no setups', () async {
      File(paths.companyJsonPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('{oops');
      expect(await CompanyService(paths: paths).load(), isEmpty);
    });
  });

  group('Doctor', () {
    late Directory home;
    late PlatformPaths paths;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_company_doc_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      File(paths.companyJsonPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'companies': [CompanySetup.parse(_acmeJson).toJson()],
          }),
        );
    });
    tearDown(() => home.delete(recursive: true));

    Future<List<DoctorIssue>> run(
      List<Profile> profiles,
      List<RepoRule> rules,
    ) async => (await IdentityDoctorService(paths: paths).run(
      profiles: profiles,
      rules: rules,
      sshKeys: const [],
    )).where((i) => i.category.name.startsWith('company')).toList();

    test(
      'warns about organizations without a profile, suggesting the work one',
      () async {
        final issues = await run(
          [_work, _personal],
          [RepoRule.account(id: 'r', owner: 'acme', profileId: 'work')],
        );
        expect(issues, hasLength(1));
        final i = issues.single;
        expect(i.category, DoctorCategory.companyOwnerUnmapped);
        expect(i.severity, Severity.warning);
        expect(i.githubOwner, 'acme-labs');
        expect(i.profileId, 'work');
        expect(i.message, contains('should use "Work"'));
        expect(fixesFor(i), [DoctorFix.useCompanyProfile]);
      },
    );

    test('blocks when an organization uses a non-company email', () async {
      final issues = await run(
        [_work, _personal],
        [
          RepoRule.account(id: 'r1', owner: 'acme', profileId: 'me'),
          RepoRule.account(id: 'r2', owner: 'acme-labs', profileId: 'work'),
        ],
      );
      expect(issues, hasLength(1));
      final i = issues.single;
      expect(i.category, DoctorCategory.companyEmailMismatch);
      expect(i.severity, Severity.blocking);
      expect(i.ruleId, 'r1');
      expect(i.profileId, 'work');
      expect(i.message, contains('me@gmail.com'));
      expect(fixesFor(i), [DoctorFix.useCompanyProfile]);
    });

    test('says when no profile has a company email; no fix to offer', () async {
      final issues = await run([_personal], const []);
      expect(issues.map((i) => i.category), [
        DoctorCategory.companyNoProfile,
        DoctorCategory.companyOwnerUnmapped,
        DoctorCategory.companyOwnerUnmapped,
      ]);
      expect(issues.every((i) => fixesFor(i).isEmpty), isTrue);
    });

    test('all quiet when everything is set up', () async {
      expect(
        await run(
          [_work, _personal],
          [
            RepoRule.account(id: 'r1', owner: 'ACME', profileId: 'work'),
            RepoRule.account(id: 'r2', owner: 'acme-labs', profileId: 'work'),
          ],
        ),
        isEmpty,
      );
    });
  });

  group('clone suggestion', () {
    test('an organization rule wins over the GitHub login match', () {
      final rules = [
        RepoRule.account(id: 'r', owner: 'meongithub', profileId: 'work'),
      ];
      expect(
        CloneService.suggestProfile('git@github.com:MeOnGitHub/blog.git', [
          _work,
          _personal,
        ], rules: rules)?.id,
        'work',
      );
      expect(
        CloneService.suggestProfile('https://github.com/acme-dev/api', [
          _work,
          _personal,
        ], rules: rules)?.id,
        'work',
      );
      // A rule for a deleted profile falls back to the login match.
      expect(
        CloneService.suggestProfile(
          'git@github.com:MeOnGitHub/blog.git',
          [_personal],
          rules: [
            RepoRule.account(id: 'x', owner: 'meongithub', profileId: 'gone'),
          ],
        )?.id,
        'me',
      );
    });
  });

  group('parseOwnerInput', () {
    test('accepts a name, host/name or a project address', () {
      expect(parseOwnerInput('acme'), (host: 'github.com', owner: 'acme'));
      expect(parseOwnerInput(' github.com/Acme '), (
        host: 'github.com',
        owner: 'Acme',
      ));
      expect(parseOwnerInput('github.com/acme/'), (
        host: 'github.com',
        owner: 'acme',
      ));
      expect(parseOwnerInput('https://github.com/acme/api.git'), (
        host: 'github.com',
        owner: 'acme',
      ));
      expect(parseOwnerInput('git@github.com:acme/api.git'), (
        host: 'github.com',
        owner: 'acme',
      ));
      expect(parseOwnerInput('ghe.corp.example/team'), (
        host: 'ghe.corp.example',
        owner: 'team',
      ));
      for (final bad in [
        '',
        'two words',
        '-acme',
        'github.com/',
        'https://github.com',
        'a/b@c',
      ]) {
        expect(parseOwnerInput(bad), isNull, reason: bad);
      }
    });
  });

  group('gita company', () {
    late Directory home;
    late PlatformPaths paths;
    late StringBuffer out;
    late StringBuffer err;
    late File setupFile;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_company_cli_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      out = StringBuffer();
      err = StringBuffer();
      setupFile = File('${home.path}/acme.json')..writeAsStringSync(_acmeJson);
    });
    tearDown(() => home.delete(recursive: true));

    Future<int> run(List<String> args) => GitaCli(
      out: out,
      err: err,
      paths: paths,
      gitService: GitService(
        environmentOverride: {
          'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
          'GIT_CONFIG_SYSTEM': '${home.path}/nosystem',
        },
      ),
      tokenStore: TokenStore(keychain: InMemoryKeychainStore()),
      input: const Stream.empty(),
    ).run(args);

    String all() => '$out$err';

    test('list with nothing imported', () async {
      expect(await run(['company', 'list']), 0);
      expect(out.toString(), contains('No company setup yet'));
    });

    test('import needs a profile first', () async {
      expect(await run(['company', 'import', setupFile.path]), 2);
      expect(all(), contains('no profiles yet'));
    });

    test('missing or broken files', () async {
      await ProfileRepository(paths: paths).upsert(_work);
      expect(await run(['company', 'import', '${home.path}/nope.json']), 2);
      expect(all(), contains("There's no file"));
      final bad = File('${home.path}/bad.json')
        ..writeAsStringSync('{"name": "X"}');
      expect(await run(['company', 'import', bad.path]), 2);
      expect(all(), contains('GitHub organizations'));
      expect(await run(['company']), 2);
      expect(await run(['company', 'frobnicate', 'x']), 2);
    });

    test('import picks the work profile, then list shows it', () async {
      await ProfileRepository(paths: paths).upsert(_work);
      await ProfileRepository(paths: paths).upsert(_personal);
      expect(
        await run(['company', 'import', setupFile.path]),
        0,
        reason: all(),
      );
      expect(out.toString(), contains('now use "Work"'));
      out.clear();
      expect(await run(['company', 'list']), 0);
      expect(
        out.toString(),
        contains('github.com/acme-labs  ->  Work <dev@acme.com>'),
      );
      out.clear();
      expect(await run(['profiles']), 0);
      expect(out.toString(), contains('github.com/acme'));
    });

    test(
      'asks which profile when none or several have a company email',
      () async {
        await ProfileRepository(paths: paths).upsert(_personal);
        expect(await run(['company', 'import', setupFile.path]), 2);
        expect(all(), contains('--profile'));
        err.clear();
        out.clear();
        expect(
          await run([
            'company',
            'import',
            setupFile.path,
            '--profile',
            'Nobody',
          ]),
          2,
        );
        expect(all(), contains('no profile called "Nobody"'));
        out.clear();
        expect(
          await run([
            'company',
            'import',
            setupFile.path,
            '--profile',
            'Personal',
            '--json',
          ]),
          0,
        );
        final json = jsonDecode(out.toString().trim()) as Map<String, dynamic>;
        expect(json['ok'], isTrue);
        expect(json['profile'], 'me');
        expect(json['added'], ['acme', 'acme-labs']);
        expect(json['message'], contains('not a Acme email'));
      },
    );

    test('list --json', () async {
      await ProfileRepository(paths: paths).upsert(_work);
      await run(['company', 'import', setupFile.path]);
      out.clear();
      expect(await run(['company', 'list', '--json']), 0);
      final json = jsonDecode(out.toString().trim()) as Map<String, dynamic>;
      expect((json['companies'] as List).single['name'], 'Acme');
    });
  });
}
