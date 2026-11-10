import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/doctor_issue.dart';
import 'package:gita/core/models/mismatch_report.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/models/ssh_key.dart';
import 'package:gita/core/models/tracked_repo.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/cli_installer.dart';
import 'package:gita/core/services/doctor_fixes.dart';
import 'package:gita/core/services/git_config_sync.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/hook_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/legacy_tokens.dart';
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

void main() {
  final work = Profile(
    id: 'work',
    label: 'Work',
    gitName: 'Dev Work',
    gitEmail: 'dev@work.example.com',
    sshKeyId: 'key-1',
    gpgKeyId: 'ABC123',
    githubLogin: 'dev-work',
    signCommitsByDefault: true,
    colorArgb: 0xFF0000AA,
    createdAt: DateTime(2026, 1, 1),
  );

  group('fixesFor', () {
    DoctorIssue issue(DoctorCategory c) =>
        DoctorIssue(category: c, severity: Severity.warning, message: 'x');

    test('offers a fix for every category Gita can repair', () {
      expect(fixesFor(issue(DoctorCategory.gpgNotInstalled)), [DoctorFix.turnOffSigning]);
      expect(fixesFor(issue(DoctorCategory.missingSigningKey)), [DoctorFix.turnOffSigning]);
      expect(fixesFor(issue(DoctorCategory.missingSshKeyFile)),
          [DoctorFix.setUpSshKey, DoctorFix.unlinkSshKey]);
      expect(fixesFor(issue(DoctorCategory.orphanedSshKeyReference)), [DoctorFix.unlinkSshKey]);
      expect(fixesFor(issue(DoctorCategory.orphanedRuleProfile)), [DoctorFix.deleteRule]);
      expect(fixesFor(issue(DoctorCategory.missingPushToken)), [DoctorFix.signIn]);
      expect(fixesFor(issue(DoctorCategory.signInRejected)), [DoctorFix.signIn]);
      expect(fixesFor(issue(DoctorCategory.signInWrongAccount)), [DoctorFix.signIn]);
      expect(fixesFor(issue(DoctorCategory.credentialHelperNotInstalled)), [DoctorFix.installCli]);
      expect(fixesFor(issue(DoctorCategory.keychainUnavailable)), isEmpty);
    });

    test('every fix has a short button label', () {
      for (final f in DoctorFix.values) {
        expect(f.label.split(' ').length, lessThanOrEqualTo(5), reason: f.label);
      }
      for (final f in RepoFix.values) {
        expect(f.label, isNotEmpty);
      }
    });
  });

  group('Profile.copyWith', () {
    test('can clear the optional fields', () {
      final cleared = work.copyWith(clearSshKeyId: true, clearGpgKeyId: true, clearGithubLogin: true);
      expect(cleared.sshKeyId, isNull);
      expect(cleared.gpgKeyId, isNull);
      expect(cleared.githubLogin, isNull);
      expect(cleared.gitEmail, work.gitEmail);
      expect(cleared.signCommitsByDefault, isTrue);
    });

    test('keeps the fields when not asked to clear them', () {
      final same = work.copyWith(label: 'Job');
      expect(same.sshKeyId, 'key-1');
      expect(same.gpgKeyId, 'ABC123');
      expect(same.githubLogin, 'dev-work');
    });
  });

  group('with a temp home', () {
    late Directory home;
    late Directory workspace;
    late String repoPath;
    late PlatformPaths paths;
    late GitService git;
    late TokenStore tokens;
    late ProviderContainer container;
    late Directory bundle;

    Future<ProcessResult> gitIn(List<String> args) => git.raw(args, workingDir: repoPath);

    Future<String?> localConfig(String key) async {
      final r = await gitIn(['config', '--local', '--get', key]);
      return r.exitCode == 0 ? (r.stdout as String).trim() : null;
    }

    String includeFile(String id) =>
        File(p.join(paths.profilesDir, '$id.gitconfig')).readAsStringSync();

    setUp(() async {
      home = await Directory.systemTemp.createTemp('gita_fix_home_');
      workspace = await Directory.systemTemp.createTemp('gita_fix_ws_');
      bundle = await Directory.systemTemp.createTemp('gita_fix_bundle_');
      paths = PlatformPaths(overrideHomeDir: home.path);
      git = GitService(environmentOverride: {
        'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
        'GIT_CONFIG_SYSTEM': '${home.path}/gitconfig_system',
      });
      repoPath = (Directory('${workspace.path}/project')..createSync()).path;
      expect((await gitIn(['init', '-q'])).exitCode, 0);
      tokens = TokenStore(keychain: InMemoryKeychainStore());

      final keyFile = File(p.join(home.path, '.ssh', 'id_work'))..createSync(recursive: true);
      await SshKeyRepository(paths: paths).upsert(SshKey(
        id: 'key-1',
        label: 'Work key',
        privateKeyPath: keyFile.path,
        publicKeyPath: '${keyFile.path}.pub',
        hostAlias: 'github.com',
        realHost: 'github.com',
        createdAt: DateTime(2026, 1, 1),
      ));
      await ProfileRepository(paths: paths).upsert(work);
      await RepoRuleRepository(paths: paths).upsert(RepoRule(
        id: 'rule-work',
        pathPattern: resolveRepoPath(workspace.path),
        profileId: 'work',
      ));
      await syncGitConfig(paths: paths, hasToken: tokens.hasToken);

      container = ProviderContainer(overrides: [
        platformPathsProvider.overrideWithValue(paths),
        gitServiceProvider.overrideWithValue(git),
        secureTokenServiceProvider.overrideWithValue(
          SecureTokenService(store: tokens, legacy: _NoLegacyTokens()),
        ),
        cliInstallerProvider.overrideWithValue(CliInstaller(paths: paths, bundledDir: bundle.path)),
      ]);
    });

    tearDown(() async {
      container.dispose();
      for (final d in [home, workspace, bundle]) {
        await _deleteQuietly(d);
      }
    });

    DoctorActions actions() => container.read(doctorActionsProvider);

    Future<Profile> savedWork() async =>
        (await ProfileRepository(paths: paths).getAll()).firstWhere((p) => p.id == 'work');

    test('turnOffSigning turns signing off and keeps everything else', () async {
      final message = await actions().turnOffSigning('work');

      expect(message, contains('signing is off for "Work"'));
      final saved = await savedWork();
      expect(saved.signCommitsByDefault, isFalse);
      expect(saved.gpgKeyId, isNull);
      expect(saved.sshKeyId, 'key-1');
      expect(saved.githubLogin, 'dev-work');
    });

    test('unlinkSshKey drops the key and its sshCommand', () async {
      expect(includeFile('work'), contains('sshCommand'));

      final message = await actions().unlinkSshKey('work');

      expect(message, contains('no longer uses that SSH key'));
      expect((await savedWork()).sshKeyId, isNull);
      expect(includeFile('work'), isNot(contains('sshCommand')));
      expect(includeFile('work'), contains('email = dev@work.example.com'));
    });

    test('deleteRule removes the rule and its includeIf', () async {
      expect(File(paths.gitConfigPath).readAsStringSync(), contains('work.gitconfig'));

      expect(await actions().deleteRule('rule-work'), 'The rule is deleted.');

      expect(await RepoRuleRepository(paths: paths).getAll(), isEmpty);
      expect(File(paths.gitConfigPath).readAsStringSync(), isNot(contains('work.gitconfig')));
    });

    test('a fix for a profile that is gone says so', () async {
      expect(() => actions().turnOffSigning('nope'), throwsA(isA<StateError>()));
    });

    test('saveSignIn saves the token and turns on HTTPS pushes', () async {
      File(paths.cliPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('fake');

      final message = await actions().saveSignIn('work', token: 'gho_new', login: 'new-login');

      expect(message, contains('signed in as @new-login'));
      expect(await tokens.readToken('work'), 'gho_new');
      expect((await savedWork()).githubLogin, 'new-login');
      expect(includeFile('work'), contains('credential --profile work'));
    });

    test('installCli copies the bundled command and says it worked', () async {
      final exe = Platform.isWindows ? 'gita.exe' : 'gita';
      File(p.join(bundle.path, 'bin', exe))
        ..createSync(recursive: true)
        ..writeAsStringSync('gita build');

      final message = await actions().installCli();

      expect(message, contains('is installed'));
      expect(File(paths.cliPath).readAsStringSync(), 'gita build');
    });

    test('installCli explains a build that has no command', () async {
      final message = await actions().installCli();
      expect(message, contains("doesn't include the gita command"));
      expect(File(paths.cliPath).existsSync(), isFalse);
    });

    group('project fixes', () {
      test('a project email override is found and removed', () async {
        final fixer = container.read(repoFixerProvider);
        await gitIn(['config', '--local', 'user.email', 'wrong@example.com']);
        await gitIn(['config', '--local', 'user.name', 'Wrong']);
        final report = MismatchReport(
          repoPath: repoPath,
          type: MismatchType.identityMismatch,
          detail: 'x',
          severity: Severity.blocking,
        );

        expect(await fixer.fixFor(report), RepoFix.clearLocalIdentity);
        final message = await actions().applyRepoFix(repoPath, RepoFix.clearLocalIdentity);

        expect(message, contains("profile's name and email"));
        expect(await localConfig('user.email'), isNull);
        expect(await localConfig('user.name'), isNull);
        expect(await git.getConfigValue(repoPath, 'user.email'), 'dev@work.example.com');
        expect(await fixer.fixFor(report), RepoFix.reapplySettings);
      });

      test('clearing works when only one of name/email is set', () async {
        await gitIn(['config', '--local', 'user.name', 'Wrong']);
        await container.read(repoFixerProvider).clearLocalIdentity(repoPath);
        expect(await localConfig('user.name'), isNull);
      });

      test('a missing safety check is added and the project is tracked', () async {
        File(paths.cliPath)
          ..createSync(recursive: true)
          ..writeAsStringSync('fake');
        final report = MismatchReport(
          repoPath: repoPath,
          type: MismatchType.hookMissing,
          detail: 'x',
          severity: Severity.warning,
        );
        expect(await container.read(repoFixerProvider).fixFor(report), RepoFix.installGuard);

        final message = await actions().applyRepoFix(repoPath, RepoFix.installGuard);

        expect(message, contains('safety check is in place'));
        final hooks = HookService(paths: paths, git: git);
        expect((await hooks.status(repoPath)).state, GuardState.installed);
        final tracked = await TrackedRepoRepository(paths: paths).getAll();
        expect(tracked.single, isA<TrackedRepo>());
        expect(tracked.single.hookInstalled, isTrue);
      });

      test("re-applying writes Gita's settings back", () async {
        File(paths.gitConfigPath).writeAsStringSync('');
        File(p.join(paths.profilesDir, 'work.gitconfig')).deleteSync();
        expect(await git.getConfigValue(repoPath, 'user.email'), isNull);

        await actions().applyRepoFix(repoPath, RepoFix.reapplySettings);

        expect(await git.getConfigValue(repoPath, 'user.email'), 'dev@work.example.com');
      });

      test('no one-click fix for a folder without a rule', () async {
        final report = MismatchReport(
          repoPath: repoPath,
          type: MismatchType.noRuleMatched,
          detail: 'x',
          severity: Severity.warning,
        );
        expect(await container.read(repoFixerProvider).fixFor(report), isNull);
      });
    });
  });
}

/// Deletes a temp folder, retrying while Windows still has a file in it
/// open (git, or a virus scanner, can hold one for a moment). A folder
/// that still can't go is left for the OS to clean up rather than failing
/// a test that passed.
Future<void> _deleteQuietly(Directory d) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    if (!d.existsSync()) return;
    try {
      await d.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
