class Profile {
  final String id;
  final String label;
  final String gitName;
  final String gitEmail;
  final String? sshKeyId;
  final String? gpgKeyId;

  /// The GitHub account this profile's token belongs to, recorded when the
  /// person signs in with GitHub. Null for pasted tokens or no token.
  final String? githubLogin;
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
    this.githubLogin,
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
    String? githubLogin,
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
      githubLogin: githubLogin ?? this.githubLogin,
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
      githubLogin: json['githubLogin'] as String?,
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
        if (githubLogin != null) 'githubLogin': githubLogin,
        'signCommitsByDefault': signCommitsByDefault,
        'colorArgb': colorArgb,
        'createdAt': createdAt.toIso8601String(),
      };
}
