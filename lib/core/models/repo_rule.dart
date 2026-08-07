class RepoRule {
  final String id;
  final String pathPattern;
  final String profileId;
  final int priority;

  const RepoRule({
    required this.id,
    required this.pathPattern,
    required this.profileId,
    this.priority = 0,
  });

  factory RepoRule.fromJson(Map<String, dynamic> json) {
    return RepoRule(
      id: json['id'] as String,
      pathPattern: json['pathPattern'] as String,
      profileId: json['profileId'] as String,
      priority: json['priority'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pathPattern': pathPattern,
        'profileId': profileId,
        'priority': priority,
      };

  /// Longest-prefix match wins; explicit priority is the tiebreaker.
  ///
  /// Both sides are normalized to forward slashes before comparing: rules
  /// created before this normalization was added may still have
  /// backslash-separated `pathPattern`s on Windows, and comparing those
  /// raw against a forward-slash repo path (as `git rev-parse
  /// --show-toplevel` always returns) would silently never match.
  static RepoRule? bestMatchFor(String repoPath, List<RepoRule> rules) {
    final normalizedRepo = _withTrailingSlash(repoPath.replaceAll('\\', '/'));
    final matches = rules.where((r) {
      final pattern = _withTrailingSlash(r.pathPattern.replaceAll('\\', '/'));
      return normalizedRepo.startsWith(pattern);
    }).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final aLen = a.pathPattern.replaceAll('\\', '/').length;
      final bLen = b.pathPattern.replaceAll('\\', '/').length;
      final lenCompare = bLen.compareTo(aLen);
      if (lenCompare != 0) return lenCompare;
      return b.priority.compareTo(a.priority);
    });
    return matches.first;
  }

  static String _withTrailingSlash(String path) =>
      path.endsWith('/') ? path : '$path/';
}
