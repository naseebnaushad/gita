class Profile {
  final String id;
  final String label;
  final String gitName;
  final String gitEmail;
  final String? sshKeyId;
  final String? gpgKeyId;
  final bool signCommitsByDefault;
  final int colorArgb;
  final DateTime createdAt;

  const Profile({
    required this.id,
    required this.label,
    required this.gitName,
    required this.gitEmail,
    this.sshKeyId,
    this.gpgKeyId,
    this.signCommitsByDefault = false,
    required this.colorArgb,
    required this.createdAt,
  });

  Profile copyWith({
    String? label,
    String? gitName,
    String? gitEmail,
    String? sshKeyId,
    String? gpgKeyId,
    bool? signCommitsByDefault,
    int? colorArgb,
  }) {
    return Profile(
      id: id,
      label: label ?? this.label,
      gitName: gitName ?? this.gitName,
      gitEmail: gitEmail ?? this.gitEmail,
      sshKeyId: sshKeyId ?? this.sshKeyId,
      gpgKeyId: gpgKeyId ?? this.gpgKeyId,
      signCommitsByDefault: signCommitsByDefault ?? this.signCommitsByDefault,
      colorArgb: colorArgb ?? this.colorArgb,
      createdAt: createdAt,
    );
  }

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String,
      label: json['label'] as String,
      gitName: json['gitName'] as String,
      gitEmail: json['gitEmail'] as String,
      sshKeyId: json['sshKeyId'] as String?,
      gpgKeyId: json['gpgKeyId'] as String?,
      signCommitsByDefault: json['signCommitsByDefault'] as bool? ?? false,
      colorArgb: json['colorArgb'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'gitName': gitName,
        'gitEmail': gitEmail,
        'sshKeyId': sshKeyId,
        'gpgKeyId': gpgKeyId,
        'signCommitsByDefault': signCommitsByDefault,
        'colorArgb': colorArgb,
        'createdAt': createdAt.toIso8601String(),
      };
}
