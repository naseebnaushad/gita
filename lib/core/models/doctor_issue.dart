import 'mismatch_report.dart' show Severity;

enum DoctorCategory {
  gpgNotInstalled,
  missingSigningKey,
  missingSshKeyFile,
  orphanedSshKeyReference,
  orphanedRuleProfile,

  /// A profile has no saved GitHub sign-in, so HTTPS pushes fall back to
  /// whichever account this computer happens to remember.
  missingPushToken,

  /// A profile has a saved sign-in, but the `gita` command git needs to
  /// use it isn't installed.
  credentialHelperNotInstalled,

  /// The OS credential store couldn't be read at all.
  keychainUnavailable,

  /// A company organization's projects use a profile without a company
  /// email.
  companyEmailMismatch,

  /// No profile commits with the company's email.
  companyNoProfile,

  /// A company organization has no account rule, so its projects use
  /// whatever their folder says.
  companyOwnerUnmapped,
}

/// A config-drift problem found by [IdentityDoctorService], independent of
/// any specific repo — the kind of thing (e.g. signing enabled with no
/// matching GPG key) that otherwise only surfaces later as a failed commit
/// or push. Complements [MismatchReport], which is scoped to one repo's
/// live state.
class DoctorIssue {
  final DoctorCategory category;
  final Severity severity;
  final String message;
  final String? profileId;
  final String? ruleId;
  final String? sshKeyId;

  /// For company issues: the GitHub organization and its host.
  final String? githubOwner;
  final String? host;

  const DoctorIssue({
    required this.category,
    required this.severity,
    required this.message,
    this.profileId,
    this.ruleId,
    this.sshKeyId,
    this.githubOwner,
    this.host,
  });
}
