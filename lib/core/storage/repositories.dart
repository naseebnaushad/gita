import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/ssh_key.dart';
import '../models/tracked_repo.dart';
import '../services/platform_paths.dart';
import 'json_store.dart';

/// Thin CRUD wrapper over [JsonStore] keyed by each model's id/path.
/// Every mutation reads-modifies-writes the whole file — fine at the
/// dozens-of-records scale this app targets (plan §12).
class ProfileRepository {
  ProfileRepository({PlatformPaths paths = const PlatformPaths()})
      : _store = JsonStore<Profile>(
          path: paths.profilesJsonPath,
          fromJson: Profile.fromJson,
          toJson: (p) => p.toJson(),
        );

  final JsonStore<Profile> _store;

  Future<List<Profile>> getAll() => _store.readAll();

  Future<void> upsert(Profile profile) async {
    final all = await _store.readAll();
    final next = [
      ...all.where((p) => p.id != profile.id),
      profile,
    ];
    await _store.writeAll(next);
  }

  Future<void> delete(String id) async {
    final all = await _store.readAll();
    await _store.writeAll(all.where((p) => p.id != id).toList());
  }
}

class RepoRuleRepository {
  RepoRuleRepository({PlatformPaths paths = const PlatformPaths()})
      : _store = JsonStore<RepoRule>(
          path: paths.rulesJsonPath,
          fromJson: RepoRule.fromJson,
          toJson: (r) => r.toJson(),
        );

  final JsonStore<RepoRule> _store;

  Future<List<RepoRule>> getAll() => _store.readAll();

  Future<void> upsert(RepoRule rule) async {
    final all = await _store.readAll();
    final next = [
      ...all.where((r) => r.id != rule.id),
      rule,
    ];
    await _store.writeAll(next);
  }

  Future<void> delete(String id) async {
    final all = await _store.readAll();
    await _store.writeAll(all.where((r) => r.id != id).toList());
  }
}

class SshKeyRepository {
  SshKeyRepository({PlatformPaths paths = const PlatformPaths()})
      : _store = JsonStore<SshKey>(
          path: paths.sshKeysJsonPath,
          fromJson: SshKey.fromJson,
          toJson: (k) => k.toJson(),
        );

  final JsonStore<SshKey> _store;

  Future<List<SshKey>> getAll() => _store.readAll();

  Future<void> upsert(SshKey key) async {
    final all = await _store.readAll();
    final next = [
      ...all.where((k) => k.id != key.id),
      key,
    ];
    await _store.writeAll(next);
  }

  Future<void> delete(String id) async {
    final all = await _store.readAll();
    await _store.writeAll(all.where((k) => k.id != id).toList());
  }
}

class TrackedRepoRepository {
  TrackedRepoRepository({PlatformPaths paths = const PlatformPaths()})
      : _store = JsonStore<TrackedRepo>(
          path: paths.trackedReposJsonPath,
          fromJson: TrackedRepo.fromJson,
          toJson: (r) => r.toJson(),
        );

  final JsonStore<TrackedRepo> _store;

  Future<List<TrackedRepo>> getAll() => _store.readAll();

  Future<void> upsert(TrackedRepo repo) async {
    final all = await _store.readAll();
    final next = [
      ...all.where((r) => r.path != repo.path),
      repo,
    ];
    await _store.writeAll(next);
  }

  Future<void> delete(String path) async {
    final all = await _store.readAll();
    await _store.writeAll(all.where((r) => r.path != path).toList());
  }
}
