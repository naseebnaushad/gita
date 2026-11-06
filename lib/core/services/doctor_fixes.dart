import '../models/doctor_issue.dart';
import '../models/mismatch_report.dart';
import 'git_service.dart';

/// A one-click repair Doctor can offer for a [DoctorIssue].
enum DoctorFix {
  /// Turn commit signing off for the profile.
  turnOffSigning,

  /// Stop the profile from using an SSH key that's gone.
  unlinkSshKey,

  /// Open the profile so a new SSH key can be set up.
  setUpSshKey,

  /// Remove a folder rule whose profile was deleted.
  deleteRule,

  /// Sign the profile in to GitHub.
  signIn,

  /// Put the `gita` command in place again.
  installCli,
}

extension DoctorFixText on DoctorFix {
  String get label => switch (this) {
        DoctorFix.turnOffSigning => 'Turn off signing',
        DoctorFix.unlinkSshKey => 'Stop using this key',
        DoctorFix.setUpSshKey => 'Set up a new key',
        DoctorFix.deleteRule => 'Delete this rule',
        DoctorFix.signIn => 'Sign in with GitHub',
        DoctorFix.installCli => 'Install it now',
      };
}

/// The fixes Doctor offers for [issue], the recommended one first. Empty
/// when the person has to sort it out outside Gita.
List<DoctorFix> fixesFor(DoctorIssue issue) => switch (issue.category) {
      DoctorCategory.gpgNotInstalled => const [DoctorFix.turnOffSigning],
      DoctorCategory.missingSigningKey => const [DoctorFix.turnOffSigning],
      DoctorCategory.missingSshKeyFile => const [DoctorFix.setUpSshKey, DoctorFix.unlinkSshKey],
      DoctorCategory.orphanedSshKeyReference => const [DoctorFix.unlinkSshKey],
      DoctorCategory.orphanedRuleProfile => const [DoctorFix.deleteRule],
      DoctorCategory.missingPushToken => const [DoctorFix.signIn],
      DoctorCategory.credentialHelperNotInstalled => const [DoctorFix.installCli],
      DoctorCategory.keychainUnavailable => const [],
    };

/// A one-click repair the Dashboard can offer for one project.
enum RepoFix {
  /// Add (or update) Gita's safety check.
  installGuard,

  /// Remove a `user.name`/`user.email` set inside the project, which
  /// overrides the profile Gita picked.
  clearLocalIdentity,

  /// Rewrite Gita's git settings, in case they were edited or removed.
  reapplySettings,
}

extension RepoFixText on RepoFix {
  String get label => switch (this) {
        RepoFix.installGuard => 'Add safety check',
        RepoFix.clearLocalIdentity => "Use the profile's email",
        RepoFix.reapplySettings => "Re-apply Gita's settings",
      };
}

/// Works out and applies one-click repairs for a project's
/// [MismatchReport].
class RepoFixer {
  const RepoFixer({this.git = const GitService()});

  final GitService git;

  /// The fix to offer for [report], or null if there's nothing Gita can
  /// do with one click.
  Future<RepoFix?> fixFor(MismatchReport report) async {
    switch (report.type) {
      case MismatchType.hookMissing:
        return RepoFix.installGuard;
      case MismatchType.identityMismatch:
        return await hasLocalIdentity(report.repoPath)
            ? RepoFix.clearLocalIdentity
            : RepoFix.reapplySettings;
      case MismatchType.noRuleMatched:
      case MismatchType.sshKeyMismatch:
        return null;
    }
  }

  /// Whether the project sets its own `user.email` or `user.name`.
  Future<bool> hasLocalIdentity(String repoPath) async {
    for (final key in const ['user.email', 'user.name']) {
      final result = await git.raw(['config', '--local', '--get', key], workingDir: repoPath);
      if (result.exitCode == 0 && (result.stdout as String).trim().isNotEmpty) return true;
    }
    return false;
  }

  /// Removes the project's own `user.name`/`user.email`, so the profile
  /// Gita picked for its folder applies. Throws [GitServiceException] if
  /// git refuses.
  Future<void> clearLocalIdentity(String repoPath) async {
    for (final key in const ['user.email', 'user.name']) {
      final result =
          await git.raw(['config', '--local', '--unset-all', key], workingDir: repoPath);
      // 5 = the key wasn't set, which is fine.
      if (result.exitCode != 0 && result.exitCode != 5) {
        throw GitServiceException(
          "Couldn't remove $key from this project: ${(result.stderr as String).trim()}",
        );
      }
    }
  }
}
