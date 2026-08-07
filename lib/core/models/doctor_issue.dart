import 'mismatch_report.dart' show Severity;

enum DoctorCategory {
  gpgNotInstalled,
  missingSigningKey,
  missingSshKeyFile,
  orphanedSshKeyReference,
  orphanedRuleProfile,
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

  const DoctorIssue({
    required this.category,
    required this.severity,
    required this.message,
    this.profileId,
    this.ruleId,
    this.sshKeyId,
  });
}
