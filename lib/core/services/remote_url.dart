/// Reads the host and owner out of a git remote address, in any of the
/// forms people copy from GitHub: `https://github.com/acme/api.git`,
/// `https://user@github.com/acme/api`, `git@github.com:acme/api.git`, or
/// `ssh://git@github.com/acme/api.git`.
class RemoteUrl {
  const RemoteUrl({required this.host, required this.path});

  /// Lower-case host, without user or port, e.g. `github.com`.
  final String host;

  /// The path after the host, without leading slash, e.g. `acme/api.git`.
  final String path;

  static final _scpLike = RegExp(r'^[\w.-]+@([\w.-]+):(.+)$');

  static RemoteUrl? parse(String url) {
    final u = url.trim();
    if (u.isEmpty) return null;
    if (!u.contains('://')) {
      final scp = _scpLike.firstMatch(u);
      if (scp == null) return null;
      return RemoteUrl(
        host: scp.group(1)!.toLowerCase(),
        path: _trim(scp.group(2)!),
      );
    }
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) return null;
    return RemoteUrl(host: uri.host.toLowerCase(), path: _trim(uri.path));
  }

  static String _trim(String path) {
    var s = path.replaceAll('\\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    return s;
  }

  List<String> get _parts =>
      path.split('/').where((s) => s.isNotEmpty).toList();

  /// The account or organization right above the project, e.g. `acme`.
  String? get owner {
    final parts = _parts;
    return parts.length >= 2 ? parts[parts.length - 2] : null;
  }

  /// The first part of the path: on GitHub, the account or organization.
  String? get topOwner {
    final parts = _parts;
    return parts.length >= 2 ? parts.first : null;
  }
}
