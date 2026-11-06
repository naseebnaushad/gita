import '../models/profile.dart';
import '../storage/repositories.dart';
import 'gitconfig_service.dart';
import 'platform_paths.dart';
import 'ssh_key_service.dart';

/// Rewrites every profile's include file and the managed `includeIf` block
/// in `~/.gitconfig` from what Gita has saved.
///
/// Shared by the app and the `gita` command, so both leave git set up the
/// same way. Call it after anything that changes a profile, a rule, an SSH
/// key, or whether a profile has a saved sign-in (which turns its HTTPS
/// credential helper on or off).
Future<void> syncGitConfig({
  required PlatformPaths paths,
  required Future<bool> Function(String profileId) hasToken,
  List<Profile>? profiles,
}) async {
  final all = profiles ?? await ProfileRepository(paths: paths).getAll();
  final gitConfig = GitConfigService(paths: paths);
  final sshKeyService = SshKeyService(paths: paths);
  final sshKeys = {
    for (final k in await SshKeyRepository(paths: paths).getAll()) k.id: k,
  };
  for (final profile in all) {
    final sshKey = sshKeys[profile.sshKeyId];
    await gitConfig.writeProfileConfigFile(
      profile,
      sshCommand: sshKey == null ? null : sshKeyService.sshCommandFor(sshKey),
      useCredentialHelper: await hasToken(profile.id),
    );
  }
  await gitConfig.syncManagedIncludeIfBlock(
    rules: await RepoRuleRepository(paths: paths).getAll(),
    profilesById: {for (final p in all) p.id: p},
  );
}
