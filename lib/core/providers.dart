import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/doctor_issue.dart';
import 'models/profile.dart';
import 'models/repo_rule.dart';
import 'models/ssh_key.dart';
import 'models/tracked_repo.dart';
import 'services/cli_installer.dart';
import 'services/git_config_sync.dart';
import 'services/git_service.dart';
import 'services/gitconfig_service.dart';
import 'services/github_device_flow.dart';
import 'services/github_oauth_config.dart';
import 'services/github_ssh_keys.dart';
import 'services/gpg_service.dart';
import 'services/hook_service.dart';
import 'services/identity_doctor_service.dart';
import 'services/mismatch_detector.dart';
import 'services/platform_paths.dart';
import 'services/secure_token_service.dart';
import 'services/ssh_config_service.dart';
import 'services/ssh_key_service.dart';
import 'storage/repositories.dart';

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
final cliInstallProvider = FutureProvider<CliInstallResult>((ref) async {
  final result = await ref.read(cliInstallerProvider).install();
  if (result.changed) {
    final profiles = await ref.read(profilesProvider.future);
    if (profiles.isNotEmpty) {
      await ref.read(profilesProvider.notifier).resyncGitConfig();
    }
    ref.invalidate(doctorIssuesProvider);
  }
  return result;
});

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
  /// without one are left for the user (Doctor offers to add it).
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
