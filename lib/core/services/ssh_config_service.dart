import 'dart:io';

import 'platform_paths.dart';

/// Minimal `~/.ssh/config` reader used by mismatch detection (plan §6.3
/// step 6). Full key generation / host-alias authoring lives in the SSH
/// Manager feature (Phase 2); this only resolves an existing alias to the
/// `IdentityFile` it maps to.
class SshConfigService {
  SshConfigService({this.paths = const PlatformPaths()});

  final PlatformPaths paths;

  /// Returns the `IdentityFile` configured for [hostAlias], or null if the
  /// alias isn't present in `~/.ssh/config`.
  Future<String?> resolveIdentityFile(String hostAlias) async {
    final file = File(paths.sshConfigPath);
    if (!await file.exists()) return null;

    final lines = await file.readAsLines();
    bool inMatchingHostBlock = false;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final hostMatch = RegExp(r'^Host\s+(.+)$', caseSensitive: false).firstMatch(line);
      if (hostMatch != null) {
        final aliases = hostMatch.group(1)!.split(RegExp(r'\s+'));
        inMatchingHostBlock = aliases.contains(hostAlias);
        continue;
      }

      if (!inMatchingHostBlock) continue;

      final identityMatch =
          RegExp(r'^IdentityFile\s+(.+)$', caseSensitive: false).firstMatch(line);
      if (identityMatch != null) {
        return identityMatch.group(1)!.trim();
      }
    }
    return null;
  }

  /// Parses `git@host:...` or `https://host/...` remote URLs and returns
  /// the host component (which may itself be an alias like `github-work`).
  static String? hostFromRemoteUrl(String remoteUrl) {
    final scpLike = RegExp(r'^[\w.-]+@([\w.-]+):').firstMatch(remoteUrl);
    if (scpLike != null) return scpLike.group(1);

    final uri = Uri.tryParse(remoteUrl);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return null;
  }
}
