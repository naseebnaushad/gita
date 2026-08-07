import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models/doctor_issue.dart';
import 'models/profile.dart';
import 'models/repo_rule.dart';
import 'models/ssh_key.dart';
import 'models/tracked_repo.dart';
import 'services/git_service.dart';
import 'services/gitconfig_service.dart';
import 'services/gpg_service.dart';
import 'services/identity_doctor_service.dart';
import 'services/mismatch_detector.dart';
import 'services/platform_paths.dart';
import 'services/secure_token_service.dart';
import 'services/ssh_config_service.dart';
import 'storage/repositories.dart';

final platformPathsProvider = Provider((ref) => const PlatformPaths());

final gitServiceProvider = Provider((ref) => const GitService());

final gitConfigServiceProvider =
    Provider((ref) => GitConfigService(paths: ref.watch(platformPathsProvider)));

final sshConfigServiceProvider =
    Provider((ref) => SshConfigService(paths: ref.watch(platformPathsProvider)));

final mismatchDetectorProvider = Provider(
  (ref) => MismatchDetector(
    gitService: ref.watch(gitServiceProvider),
    sshConfigService: ref.watch(sshConfigServiceProvider),
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

final secureTokenServiceProvider = Provider((ref) => const SecureTokenService());

final gpgServiceProvider = Provider((ref) => const GpgService());

final identityDoctorServiceProvider = Provider(
  (ref) => IdentityDoctorService(gpgService: ref.watch(gpgServiceProvider)),
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

  Future<void> _resyncGitConfig() async {
    final profiles = state.value ?? [];
    final gitConfigService = ref.read(gitConfigServiceProvider);
    for (final profile in profiles) {
      await gitConfigService.writeProfileConfigFile(profile);
    }
    final rules = await ref.read(repoRuleRepositoryProvider).getAll();
    await gitConfigService.syncManagedIncludeIfBlock(
      rules: rules,
      profilesById: {for (final p in profiles) p.id: p},
    );
  }
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

  Future<void> add(String path) async {
    final repo = TrackedRepo(path: path, lastScanned: DateTime.now());
    await ref.read(trackedRepoRepositoryProvider).upsert(repo);
    state = AsyncData(await ref.read(trackedRepoRepositoryProvider).getAll());
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
