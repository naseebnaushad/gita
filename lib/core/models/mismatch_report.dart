enum MismatchType {
  identityMismatch,
  noRuleMatched,
  hookMissing,
  sshKeyMismatch,
}

enum Severity { warning, blocking }

/// Computed on demand from live git state, not stored (see plan §4.5/§6.3).
class MismatchReport {
  final String repoPath;
  final MismatchType type;
  final String detail;
  final Severity severity;

  const MismatchReport({
    required this.repoPath,
    required this.type,
    required this.detail,
    required this.severity,
  });
}
