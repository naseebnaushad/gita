import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/profile.dart';
import '../models/tracked_repo.dart';
import '../storage/repositories.dart';
import 'git_config_sync.dart';
import 'git_service.dart';
import 'hook_service.dart';
import 'machine_scanner.dart';
import 'platform_paths.dart';

/// The colors new profiles get, in turn. Kept here (not in the app's
/// theme) so the `gita` command picks the same ones.
const profileColorPalette = [
  0xFF3D5AFE,
  0xFF00BFA5,
  0xFFFF6D00,
  0xFFD500F9,
  0xFFC51162,
  0xFF64DD17,
];

/// What [SetupService.apply] made.
class SetupResult {
  const SetupResult({
    required this.profiles,
    required this.newProfiles,
    required this.rules,
    required this.sshKeys,
    required this.projects,
    this.projectProblems = const [],
  });

  /// Every profile the choices map to, new or existing.
  final List<Profile> profiles;
  final int newProfiles;
  final int rules;
  final int sshKeys;
  final int projects;

  /// Projects whose safety check couldn't be added, and why.
  final List<String> projectProblems;

  Map<String, Object?> toJson() => {
        'profiles': [
          for (final pr in profiles) {'id': pr.id, 'label': pr.label, 'email': pr.gitEmail},
        ],
        'newProfiles': newProfiles,
        'rules': rules,
        'sshKeys': sshKeys,
        'projects': projects,
        'projectProblems': projectProblems,
      };
}

/// Saves what the setup wizard (or `gita setup`) suggested and the person
/// kept: profiles, SSH key records, folder rules, git settings and the
/// safety check in each project.
class SetupService {
  SetupService({
    required this.paths,
    required this.hasToken,
    this.git = const GitService(),
  });

  final PlatformPaths paths;
  final Future<bool> Function(String profileId) hasToken;
  final GitService git;

  static const _doneMarker = 'first_run_done';

  File _marker() => File(p.join(paths.gitaDir, _doneMarker));

  /// Whether the setup wizard should open by itself: no profiles yet and
  /// the person hasn't finished or skipped it before.
  Future<bool> shouldOfferSetup() async {
    if (_marker().existsSync()) return false;
    return (await ProfileRepository(paths: paths).getAll()).isEmpty;
  }

  /// Remembers that setup was finished or skipped, so the wizard doesn't
  /// open by itself again (it's still under Profiles).
  Future<void> markSetupDone() async {
    final marker = _marker();
    await marker.parent.create(recursive: true);
    await marker.writeAsString(DateTime.now().toIso8601String());
  }

  Future<SetupResult> apply(
    List<SetupChoice> choices, {
    List<int> palette = profileColorPalette,
    bool trackProjects = true,
  }) async {
    final profileRepo = ProfileRepository(paths: paths);
    final ruleRepo = RepoRuleRepository(paths: paths);
    final keyRepo = SshKeyRepository(paths: paths);
    final existingProfiles = await profileRepo.getAll();
    const uuid = Uuid();
    final plan = SetupPlan.build(
      choices: choices,
      existingKeys: await keyRepo.getAll(),
      existingRules: await ruleRepo.getAll(),
      existingProfiles: existingProfiles,
      palette: palette,
      newId: uuid.v4,
    );
    for (final key in plan.sshKeys) {
      await keyRepo.upsert(key);
    }
    for (final profile in plan.profiles) {
      await profileRepo.upsert(profile);
    }
    for (final rule in plan.rules) {
      await ruleRepo.upsert(rule);
    }
    await syncGitConfig(paths: paths, hasToken: hasToken);

    var tracked = 0;
    final problems = <String>[];
    if (trackProjects && plan.projects.isNotEmpty) {
      final hooks = HookService(paths: paths, git: git);
      final trackedRepo = TrackedRepoRepository(paths: paths);
      for (final path in plan.projects) {
        final guard = await hooks.install(path);
        await trackedRepo.upsert(TrackedRepo(
          path: path,
          lastScanned: DateTime.now(),
          hookInstalled: guard.ok,
        ));
        tracked++;
        if (!guard.ok) problems.add('$path: ${guard.message ?? 'safety check not added'}');
      }
    }
    await markSetupDone();

    final existingIds = {for (final pr in existingProfiles) pr.id};
    return SetupResult(
      profiles: plan.profiles,
      newProfiles: plan.profiles.where((pr) => !existingIds.contains(pr.id)).length,
      rules: plan.rules.length,
      sshKeys: plan.sshKeys.length,
      projects: tracked,
      projectProblems: problems,
    );
  }
}
