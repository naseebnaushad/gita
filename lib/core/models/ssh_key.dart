class SshKey {
  final String id;
  final String label;
  final String privateKeyPath;
  final String publicKeyPath;
  final String hostAlias;
  final String realHost;
  final DateTime createdAt;

  const SshKey({
    required this.id,
    required this.label,
    required this.privateKeyPath,
    required this.publicKeyPath,
    required this.hostAlias,
    required this.realHost,
    required this.createdAt,
  });

  factory SshKey.fromJson(Map<String, dynamic> json) {
    return SshKey(
      id: json['id'] as String,
      label: json['label'] as String,
      privateKeyPath: json['privateKeyPath'] as String,
      publicKeyPath: json['publicKeyPath'] as String,
      hostAlias: json['hostAlias'] as String,
      realHost: json['realHost'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'privateKeyPath': privateKeyPath,
        'publicKeyPath': publicKeyPath,
        'hostAlias': hostAlias,
        'realHost': realHost,
        'createdAt': createdAt.toIso8601String(),
      };
}
