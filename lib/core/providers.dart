
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'models/doctor_issue.dart';
import 'models/profile.dart';
import 'models/repo_rule.dart';
import 'models/ssh_key.dart';
import 'models/tracked_repo.dart';
import 'services/cli_installer.dart';
import 'services/clone_service.dart';
import 'services/company_setup.dart';
import 'services/doctor_fixes.dart';
import 'services/git_config_sync.dart';
import 'services/git_service.dart';
import 'services/gitconfig_service.dart';
import 'services/github_device_flow.dart';
import 'services/github_oauth_config.dart';
import 'services/github_ssh_keys.dart';
import 'services/gpg_service.dart';
import 'services/hook_service.dart';
import 'services/identity_doctor_service.dart';
import 'services/machine_scanner.dart';
import 'services/mismatch_detector.dart';
import 'services/platform_paths.dart';
import 'services/secure_token_service.dart';
import 'services/setup_service.dart';
import 'services/ssh_config_service.dart';
import 'services/ssh_key_service.dart';
import 'storage/repositories.dart';

export 'services/setup_service.dart' show SetupResult;

final platformPathsProvider = Provider((ref) => const PlatformPaths());

final gitServiceProvider = Provider((ref) => const GitService());

final gitConfigServiceProvider =
    Provider((ref) => GitConfigService(paths: ref.watch(platformPathsProvider)));

final sshConfigServiceProvider =
    Provider((ref) => SshConfigService(paths: ref.watch(platformPathsProvider)));

final hookServiceProvider = Provider(
  (ref) => HookService(paths: ref.watch(platformPathsProvider), git: ref.watch(gitServiceProvider)),
);

final mismatchDetectorProvider = Provider(
  (ref) => MismatchDetector(
    gitService: ref.watch(gitServiceProvider),
    sshConfigService: ref.watch(sshConfigServiceProvider),
    hookService: ref.watch(hookServiceProvider),
  ),
);

final profileRepositoryProvider =
    Provider((ref) => ProfileRepository(paths: ref.watch(platformPathsProvider)));

final repoRuleRepositoryProvider =
    Provider((ref) => RepoRuleRepository(paths: ref.watch(platformPathsProvider)));

final sshKeyRepositoryProvider =
    Provider((ref) => SshKeyRepository(paths: ref.watch(platformPathsProvider)));

final trackedRepoRepositoryProvider =
    Provider((ref) => TrackedRepoRepository(paths: ref.watch(platformPathsProvider)));

final secureTokenServiceProvider = Provider((ref) => SecureTokenService());

/// GitHub device-flow sign-in, or null when this copy of Gita has no OAuth
/// client ID configured (people paste a token instead).
final gitHubDeviceFlowProvider = Provider<GitHubDeviceFlow?>((ref) {
  final clientId = resolveGitHubClientId();
  return clientId == null ? null : GitHubDeviceFlow(clientId: clientId);
});

final sshKeyServiceProvider =
    Provider((ref) => SshKeyService(paths: ref.watch(platformPathsProvider)));

final gitHubSshKeysProvider = Provider((ref) => GitHubSshKeys());

final cliInstallerProvider =
    Provider((ref) => CliInstaller(paths: ref.watch(platformPathsProvider)));

/// Puts the `gita` command this app ships in ~/.gita/bin (or updates it)
/// and, when that changed anything, rewrites the profiles' git settings so
/// profiles with a saved GitHub sign-in start using it. Read once at
/// startup.
final cliInstallProvider = FutureProvider<CliInstallResult>(_installCli);

Future<CliInstallResult> _installCli(Ref ref) async {
  final result = await ref.read(cliInstallerProvider).install();
  if (result.changed) {
    final profiles = await ref.read(profilesProvider.future);
    if (profiles.isNotEmpty) {
      await ref.read(profilesProvider.notifier).resyncGitConfig();
    }
    ref.invalidate(doctorIssuesProvider);
  }
  return result;
}

final gpgServiceProvider = Provider((ref) => const GpgService());

final identityDoctorServiceProvider = Provider(
  (ref) => IdentityDoctorService(
    gpgService: ref.watch(gpgServiceProvider),
    paths: ref.watch(platformPathsProvider),
    tokenStore: ref.watch(secureTokenServiceProvider).store,
  ),
);

final doctorIssuesProvider = FutureProvider<List<DoctorIssue>>((ref) async {
  final profiles = await ref.watch(profilesProvider.future);
  final rules = await ref.watch(repoRulesProvider.future);
  final sshKeys = await ref.watch(sshKeysProvider.future);
  return ref.watch(identityDoctorServiceProvider).run(
        profiles: profiles,
        rules: rules,
        sshKeys: sshKeys,
      );
});

class ProfilesNotifier extends AsyncNotifier<List<Profile>> {
  @override
  Future<List<Profile>> build() => ref.watch(profileRepositoryProvider).getAll();

  Future<void> upsert(Profile profile) async {
    await ref.read(profileRepositoryProvider).upsert(profile);
    state = AsyncData(await ref.read(profileRepositoryProvider).getAll());
    await _resyncGitConfig();
  }

  Future<void> delete(String id) async {
    await ref.read(profileRepositoryProvider).delete(id);
    await ref.read(secureTokenServiceProvider).deleteToken(id);
    state = AsyncData(await ref.read(profileRepositoryProvider).getAll());
  }

  /// Rewrites every profile's include file and the managed `includeIf`
  /// block. Call after a profile's token is saved or removed, since that
  /// turns its HTTPS credential helper on or off.
  Future<void> resyncGitConfig() => _resyncGitConfig();

  Future<void> _resyncGitConfig() => syncGitConfig(
        paths: ref.read(platformPathsProvider),
        hasToken: ref.read(secureTokenServiceProvider).hasToken,
        profiles: state.value ?? const [],
      );
}

final profilesProvider = AsyncNotifierProvider<ProfilesNotifier, List<Profile>>(
  ProfilesNotifier.new,
);

class RepoRulesNotifier extends AsyncNotifier<List<RepoRule>> {
  @override
  Future<List<RepoRule>> build() => ref.watch(repoRuleRepositoryProvider).getAll();

  Future<void> upsert(RepoRule rule) async {
    await ref.read(repoRuleRepositoryProvider).upsert(rule);
    state = AsyncData(await ref.read(repoRuleRepositoryProvider).getAll());
    await _resyncGitConfig();
  }

  Future<void> delete(String id) async {
    await ref.read(repoRuleRepositoryProvider).delete(id);
    state = AsyncData(await ref.read(repoRuleRepositoryProvider).getAll());
    await _resyncGitConfig();
  }

  Future<void> _resyncGitConfig() async {
    final rules = state.value ?? [];
    final profiles = await ref.read(profileRepositoryProvider).getAll();
    await ref.read(gitConfigServiceProvider).syncManagedIncludeIfBlock(
          rules: rules,
          profilesById: {for (final p in profiles) p.id: p},
        );
  }
}

final repoRulesProvider = AsyncNotifierProvider<RepoRulesNotifier, List<RepoRule>>(
  RepoRulesNotifier.new,
);

class SshKeysNotifier extends AsyncNotifier<List<SshKey>> {
  @override
  Future<List<SshKey>> build() => ref.watch(sshKeyRepositoryProvider).getAll();

  Future<void> upsert(SshKey key) async {
    await ref.read(sshKeyRepositoryProvider).upsert(key);
    state = AsyncData(await ref.read(sshKeyRepositoryProvider).getAll());
  }

  Future<void> delete(String id) async {
    await ref.read(sshKeyRepositoryProvider).delete(id);
    state = AsyncData(await ref.read(sshKeyRepositoryProvider).getAll());
  }
}

final sshKeysProvider = AsyncNotifierProvider<SshKeysNotifier, List<SshKey>>(
  SshKeysNotifier.new,
);

class TrackedReposNotifier extends AsyncNotifier<List<TrackedRepo>> {
  @override
  Future<List<TrackedRepo>> build() => ref.watch(trackedRepoRepositoryProvider).getAll();

  /// Tracks [path] and adds Gita's safety check to it. Returns what
  /// happened with the safety check, so the screen can explain a project
  /// that runs its own hooks.
  Future<GuardResult> add(String path) async {
    final guard = await ref.read(hookServiceProvider).install(path);
    final repo = TrackedRepo(
      path: path,
      lastScanned: DateTime.now(),
      hookInstalled: guard.ok,
    );
    await ref.read(trackedRepoRepositoryProvider).upsert(repo);
    state = AsyncData(await ref.read(trackedRepoRepositoryProvider).getAll());
    return guard;
  }

  /// Brings safety checks written by an older Gita up to date. Projects
  /// without one are left for the user (the Dashboard offers to add it).
  Future<int> updateOutdatedGuards() async {
    final hooks = ref.read(hookServiceProvider);
    var updated = 0;
    for (final repo in await ref.read(trackedRepoRepositoryProvider).getAll()) {
      if ((await hooks.status(repo.path)).state != GuardState.outdated) continue;
      if ((await hooks.install(repo.path)).ok) updated++;
    }
    return updated;
  }

  Future<void> remove(String path) async {
    await ref.read(trackedRepoRepositoryProvider).delete(path);
    state = AsyncData(await ref.read(trackedRepoRepositoryProvider).getAll());
  }

  Future<void> refresh() async {
    state = AsyncData(await ref.read(trackedRepoRepositoryProvider).getAll());
  }
}

final trackedReposProvider = AsyncNotifierProvider<TrackedReposNotifier, List<TrackedRepo>>(
  TrackedReposNotifier.new,
);

final repoFixerProvider = Provider((ref) => RepoFixer(git: ref.watch(gitServiceProvider)));

final doctorActionsProvider = Provider((ref) => DoctorActions(ref));

/// The one-click repairs Doctor and the Dashboard offer. Each returns a
/// short, plain sentence saying what changed, for a snackbar.
class DoctorActions {
  DoctorActions(this._ref);

  final Ref _ref;

  Future<Profile> _profile(String id) async {
    final profiles = await _ref.read(profilesProvider.future);
    return profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => throw StateError('That profile no longer exists.'),
    );
  }

  Future<String> _saveProfile(Profile profile, String message) async {
    await _ref.read(profilesProvider.notifier).upsert(profile);
    _ref.invalidate(doctorIssuesProvider);
    return message;
  }

  Future<String> turnOffSigning(String profileId) async {
    final profile = await _profile(profileId);
    return _saveProfile(
      profile.copyWith(signCommitsByDefault: false, clearGpgKeyId: true),
      'Commit signing is off for "${profile.label}", so its commits work again.',
    );
  }

  Future<String> unlinkSshKey(String profileId) async {
    final profile = await _profile(profileId);
    return _saveProfile(
      profile.copyWith(clearSshKeyId: true),
      '"${profile.label}" no longer uses that SSH key. Its HTTPS pushes use '
      'its GitHub sign-in; set up a new key under Profiles to push over SSH.',
    );
  }

  /// Makes projects from the issue's GitHub organization use the
  /// company profile Doctor suggested.
  Future<String> useCompanyProfile(DoctorIssue issue) async {
    final profile = await _profile(issue.profileId!);
    final owner = issue.githubOwner!;
    final host = issue.host ?? RepoRule.defaultHost;
    final rules = await _ref.read(repoRulesProvider.future);
    final existing = rules
        .where(
          (r) =>
              r.isAccountRule &&
              r.host == host &&
              r.githubOwner!.toLowerCase() == owner.toLowerCase(),
        )
        .firstOrNull;
    await _ref
        .read(repoRulesProvider.notifier)
        .upsert(
          RepoRule.account(
            id: existing?.id ?? const Uuid().v4(),
            owner: existing?.githubOwner ?? owner,
            profileId: profile.id,
            host: host,
          ),
        );
    _ref.invalidate(doctorIssuesProvider);
    return 'Projects from $host/$owner now use "${profile.label}" (${profile.gitEmail}).';
  }

  Future<String> deleteRule(String ruleId) async {
    await _ref.read(repoRulesProvider.notifier).delete(ruleId);
    _ref.invalidate(doctorIssuesProvider);
    return 'The rule is deleted.';
  }

  /// Saves a finished GitHub sign-in for [profileId] and turns on HTTPS
  /// pushes for it.
  Future<String> saveSignIn(String profileId, {required String token, required String login}) async {
    final profile = await _profile(profileId);
    // The token first: saving the profile rewrites its git settings, which
    // turn the HTTPS sign-in on only when a token is stored.
    await _ref.read(secureTokenServiceProvider).saveToken(profileId, token);
    return _saveProfile(
      profile.copyWith(githubLogin: login),
      '"${profile.label}" is signed in as @$login. HTTPS pushes from its '
      'folders now use this account.',
    );
  }

  Future<String> installCli() async {
    final result = await _installCli(_ref);
    _ref.invalidate(doctorIssuesProvider);
    return switch (result.status) {
      CliInstallStatus.installed ||
      CliInstallStatus.updated ||
      CliInstallStatus.upToDate =>
        'The gita command is installed. Saved GitHub sign-ins now work for pushes.',
      CliInstallStatus.notBundled =>
        "This copy of Gita doesn't include the gita command. Reinstall Gita "
            'from the latest release.',
      CliInstallStatus.failed =>
        "Couldn't install the gita command: ${result.message ?? 'unknown error'}. "
            'Close other Gita windows and try again.',
    };
  }

  /// Applies [fix] to the project at [repoPath], then refreshes the
  /// Dashboard so its rows show the new state.
  Future<String> applyRepoFix(String repoPath, RepoFix fix) async {
    final message = await _applyRepoFix(repoPath, fix);
    await _ref.read(trackedReposProvider.notifier).refresh();
    return message;
  }

  Future<String> _applyRepoFix(String repoPath, RepoFix fix) async {
    switch (fix) {
      case RepoFix.installGuard:
        final guard = await _ref.read(trackedReposProvider.notifier).add(repoPath);
        return guard.ok
            ? 'The safety check is in place. Commits and pushes with the wrong '
                'account will be stopped.'
            : guard.message ?? "Couldn't add the safety check.";
      case RepoFix.clearLocalIdentity:
        await _ref.read(repoFixerProvider).clearLocalIdentity(repoPath);
        return "This project now commits with its profile's name and email.";
      case RepoFix.reapplySettings:
        // Profiles must be loaded, or the rewrite would see none.
        await _ref.read(profilesProvider.future);
        await _ref.read(profilesProvider.notifier).resyncGitConfig();
        return "Gita's git settings are written again.";
    }
  }
}

final machineScannerProvider = Provider(
  (ref) => MachineScanner(paths: ref.watch(platformPathsProvider), git: ref.watch(gitServiceProvider)),
);

final setupActionsProvider = Provider((ref) => SetupActions(ref));

final cloneServiceProvider = Provider(
  (ref) => CloneService(paths: ref.watch(platformPathsProvider), git: ref.watch(gitServiceProvider)),
);

/// Clones a project as a profile, then refreshes the screens that show
/// rules and projects.
final cloneActionsProvider = Provider((ref) => CloneActions(ref));

class CloneActions {
  CloneActions(this._ref);

  final Ref _ref;

  Future<CloneOutcome> clone({
    required String url,
    required String destination,
    required Profile profile,
    void Function(String line)? onProgress,
  }) async {
    final outcome = await _ref.read(cloneServiceProvider).clone(
          url: url,
          destination: destination,
          profile: profile,
          hasToken: _ref.read(secureTokenServiceProvider).hasToken,
          onProgress: onProgress,
        );
    _ref
      ..invalidate(repoRulesProvider)
      ..invalidate(trackedReposProvider)
      ..invalidate(doctorIssuesProvider);
    return outcome;
  }
}

final companyServiceProvider = Provider(
  (ref) => CompanyService(paths: ref.watch(platformPathsProvider)),
);

/// Imports a company setup file, then refreshes rules and Doctor.
final companyActionsProvider = Provider((ref) => CompanyActions(ref));

class CompanyActions {
  CompanyActions(this._ref);

  final Ref _ref;

  Future<CompanyImportResult> import(
    CompanySetup setup,
    Profile profile,
  ) async {
    final result = await _ref
        .read(companyServiceProvider)
        .import(
          setup,
          profile,
          hasToken: _ref.read(secureTokenServiceProvider).hasToken,
        );
    _ref
      ..invalidate(repoRulesProvider)
      ..invalidate(doctorIssuesProvider);
    return result;
  }
}

/// Saves what the setup wizard suggested and the person kept, then
/// refreshes the screens that show it. The work is in [SetupService],
/// which `gita setup` shares.
class SetupActions {
  SetupActions(this._ref);

  final Ref _ref;

  SetupService get _service => SetupService(
        paths: _ref.read(platformPathsProvider),
        hasToken: _ref.read(secureTokenServiceProvider).hasToken,
        git: _ref.read(gitServiceProvider),
      );

  /// Whether to open the setup wizard by itself: no profiles yet and the
  /// person hasn't finished or skipped it before.
  Future<bool> shouldOfferSetup() => _service.shouldOfferSetup();

  /// Remembers that the wizard was finished or skipped, so it doesn't open
  /// by itself again (it's still under Profiles).
  Future<void> markSetupDone() => _service.markSetupDone();

  Future<SetupResult> apply(
    List<SetupChoice> choices, {
    required List<int> palette,
    bool trackProjects = true,
  }) async {
    try {
      return await _service.apply(choices, palette: palette, trackProjects: trackProjects);
    } finally {
      _ref
        ..invalidate(sshKeysProvider)
        ..invalidate(profilesProvider)
        ..invalidate(repoRulesProvider)
        ..invalidate(trackedReposProvider)
        ..invalidate(doctorIssuesProvider);
    }
  }
}
