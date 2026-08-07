import '../models/mismatch_report.dart';
import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/ssh_key.dart';
import 'git_service.dart';
import 'ssh_config_service.dart';

/// Implements the mismatch-detection algorithm from plan §6.3. This same
/// function backs both the Dashboard (read-only) and, in spirit, the
/// pre-push hook — the hook reimplements it in shell/PowerShell against the
/// flat rules cache rather than calling into Dart, but the steps mirror
/// exactly what happens here.
class MismatchDetector {
  MismatchDetector({
    this.gitService = const GitService(),
    SshConfigService? sshConfigService,
  }) : sshConfigService = sshConfigService ?? SshConfigService();

  final GitService gitService;
  final SshConfigService sshConfigService;

  /// Returns null when the repo is fully consistent with its expected
  /// profile (no report needed for a clean repo).
  Future<MismatchReport?> check({
    required String repoPath,
    required List<RepoRule> rules,
    required Map<String, Profile> profilesById,
    required Map<String, SshKey> sshKeysById,
  }) async {
    // Step 3: which rule governs this path (longest-prefix match).
    final rule = RepoRule.bestMatchFor(repoPath, rules);
    if (rule == null) {
      // Step 7: no rule matched — warning, not blocking; likely a new repo.
      return MismatchReport(
        repoPath: repoPath,
        type: MismatchType.noRuleMatched,
        detail: 'No Gita rule covers this folder yet.',
        severity: Severity.warning,
      );
    }

    final expectedProfile = profilesById[rule.profileId];
    if (expectedProfile == null) {
      return MismatchReport(
        repoPath: repoPath,
        type: MismatchType.noRuleMatched,
        detail: 'Rule points at a profile that no longer exists.',
        severity: Severity.warning,
      );
    }

    // Step 1: git's own resolution of user.email, including includeIf chain.
    final actualEmail = await gitService.getConfigValue(repoPath, 'user.email');

    // Step 5: compare against expected identity.
    if (actualEmail != expectedProfile.gitEmail) {
      return MismatchReport(
        repoPath: repoPath,
        type: MismatchType.identityMismatch,
        detail: actualEmail == null
            ? 'No user.email is set for this repo; expected '
                '${expectedProfile.gitEmail} (${expectedProfile.label}).'
            : 'This repo would commit as $actualEmail but is configured '
                'for ${expectedProfile.gitEmail} (${expectedProfile.label}).',
        severity: Severity.blocking,
      );
    }

    // Step 2 + 6: resolve the remote host and, if it's an alias, confirm the
    // IdentityFile it maps to matches the expected profile's SSH key.
    final remoteUrl = await gitService.getRemoteUrl(repoPath);
    if (remoteUrl != null && expectedProfile.sshKeyId != null) {
      final expectedKey = sshKeysById[expectedProfile.sshKeyId];
      final host = SshConfigService.hostFromRemoteUrl(remoteUrl);
      if (expectedKey != null && host != null && host == expectedKey.hostAlias) {
        final resolvedIdentityFile = await sshConfigService.resolveIdentityFile(host);
        if (resolvedIdentityFile != null &&
            !_samePath(resolvedIdentityFile, expectedKey.privateKeyPath)) {
          return MismatchReport(
            repoPath: repoPath,
            type: MismatchType.sshKeyMismatch,
            detail: 'Remote host alias "$host" resolves to '
                '$resolvedIdentityFile, not the expected '
                '${expectedKey.privateKeyPath} for ${expectedProfile.label}.',
            severity: Severity.blocking,
          );
        }
      }
    }

    return null;
  }

  bool _samePath(String a, String b) {
    String normalize(String s) => s.trim().replaceAll(r'\', '/');
    return normalize(a) == normalize(b);
  }
}
