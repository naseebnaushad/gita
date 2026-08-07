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
  static RepoRule? bestMatchFor(String repoPath, List<RepoRule> rules) {
    final normalizedRepo = repoPath.endsWith('/') ? repoPath : '$repoPath/';
    final matches = rules.where((r) {
      final pattern = r.pathPattern.endsWith('/')
          ? r.pathPattern
          : '${r.pathPattern}/';
      return normalizedRepo.startsWith(pattern);
    }).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final lenCompare = b.pathPattern.length.compareTo(a.pathPattern.length);
      if (lenCompare != 0) return lenCompare;
      return b.priority.compareTo(a.priority);
    });
    return matches.first;
  }
}
