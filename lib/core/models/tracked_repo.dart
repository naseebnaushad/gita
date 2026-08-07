/// Cached scan result, not source of truth — always re-verify live via
/// git_service before showing critical state (see plan §4.4).
class TrackedRepo {
  final String path;
  final String? remoteUrl;
  final String? expectedProfileId;
  final String? effectiveEmail;
  final String? effectiveSshKey;
  final bool hookInstalled;
  final DateTime lastScanned;

  const TrackedRepo({
    required this.path,
    this.remoteUrl,
    this.expectedProfileId,
    this.effectiveEmail,
    this.effectiveSshKey,
    this.hookInstalled = false,
    required this.lastScanned,
  });

  TrackedRepo copyWith({
    String? remoteUrl,
    String? expectedProfileId,
    String? effectiveEmail,
    String? effectiveSshKey,
    bool? hookInstalled,
    DateTime? lastScanned,
  }) {
    return TrackedRepo(
      path: path,
      remoteUrl: remoteUrl ?? this.remoteUrl,
      expectedProfileId: expectedProfileId ?? this.expectedProfileId,
      effectiveEmail: effectiveEmail ?? this.effectiveEmail,
      effectiveSshKey: effectiveSshKey ?? this.effectiveSshKey,
      hookInstalled: hookInstalled ?? this.hookInstalled,
      lastScanned: lastScanned ?? this.lastScanned,
    );
  }

  factory TrackedRepo.fromJson(Map<String, dynamic> json) {
    return TrackedRepo(
      path: json['path'] as String,
      remoteUrl: json['remoteUrl'] as String?,
      expectedProfileId: json['expectedProfileId'] as String?,
      effectiveEmail: json['effectiveEmail'] as String?,
      effectiveSshKey: json['effectiveSshKey'] as String?,
      hookInstalled: json['hookInstalled'] as bool? ?? false,
      lastScanned: DateTime.parse(json['lastScanned'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'remoteUrl': remoteUrl,
        'expectedProfileId': expectedProfileId,
        'effectiveEmail': effectiveEmail,
        'effectiveSshKey': effectiveSshKey,
        'hookInstalled': hookInstalled,
        'lastScanned': lastScanned.toIso8601String(),
      };
}
