import 'dart:io';

import '../models/profile.dart';
import '../models/repo_rule.dart';
import 'platform_paths.dart';

/// Reads/writes the Gita-managed section of `~/.gitconfig` and the
/// per-profile include files under `~/.gita/profiles/` (plan §6.1).
///
/// The managed block in `~/.gitconfig` is replaced by marker, never by a
/// full INI rewrite, so the user's own entries and formatting outside the
/// markers are preserved untouched.
class GitConfigService {
  GitConfigService({this.paths = const PlatformPaths()});

  final PlatformPaths paths;

  static const _startMarker =
      '# >>> Gita managed rules — do not edit below by hand >>>';
  static const _endMarker = '# <<< Gita managed rules <<<';

  /// Writes the per-profile `[user]`/`[core]`/`[commit]` include file that
  /// each `includeIf` block in `~/.gitconfig` points at.
  Future<void> writeProfileConfigFile(
    Profile profile, {
    String? sshCommand,
  }) async {
    final dir = Directory(paths.profilesDir);
    await dir.create(recursive: true);

    final buffer = StringBuffer()
      ..writeln('[user]')
      ..writeln('    name = ${profile.gitName}')
      ..writeln('    email = ${profile.gitEmail}');

    if (sshCommand != null && sshCommand.isNotEmpty) {
      buffer
        ..writeln('[core]')
        ..writeln('    sshCommand = $sshCommand');
    }

    if (profile.signCommitsByDefault) {
      buffer
        ..writeln('[commit]')
        ..writeln('    gpgsign = true');
      if (profile.gpgKeyId != null) {
        buffer
          ..writeln('[user]')
          ..writeln('    signingkey = ${profile.gpgKeyId}');
      }
    }

    final file = File(_profileConfigPath(profile.id));
    await file.writeAsString(buffer.toString());
  }

  String _profileConfigPath(String profileId) =>
      '${paths.profilesDir}/$profileId.gitconfig';

  /// Regenerates the entire managed `includeIf` block from the current set
  /// of rules and profiles, and splices it into `~/.gitconfig` between the
  /// markers (appending markers if this is the first sync).
  ///
  /// Rules are emitted most-general-path first, most-specific-path last:
  /// for a scalar key like `user.email`, git applies matching `includeIf`
  /// blocks in file order and the last match wins, so the most-specific
  /// rule must sort last to take precedence over a broader parent-folder
  /// rule.
  Future<void> syncManagedIncludeIfBlock({
    required List<RepoRule> rules,
    required Map<String, Profile> profilesById,
  }) async {
    final sorted = [...rules]
      ..sort((a, b) => a.pathPattern.length.compareTo(b.pathPattern.length));

    final block = StringBuffer()..writeln(_startMarker);
    for (final rule in sorted) {
      final profile = profilesById[rule.profileId];
      if (profile == null) continue;
      final gitDir = rule.pathPattern.endsWith('/')
          ? rule.pathPattern
          : '${rule.pathPattern}/';
      final includePath = paths.toGitConfigPath(_profileConfigPath(profile.id));
      block
        ..writeln('[includeIf "gitdir:$gitDir"]')
        ..writeln('    path = $includePath');
    }
    block.writeln(_endMarker);

    await _spliceManagedBlock(block.toString().trimRight());
  }

  Future<void> _spliceManagedBlock(String newBlock) async {
    final file = File(paths.gitConfigPath);
    final exists = await file.exists();
    final original = exists ? await file.readAsString() : '';

    final startIdx = original.indexOf(_startMarker);
    final endIdx = original.indexOf(_endMarker);

    String result;
    if (startIdx != -1 && endIdx != -1) {
      final before = original.substring(0, startIdx).trimRight();
      final after = original.substring(endIdx + _endMarker.length).trimLeft();
      final parts = [
        if (before.isNotEmpty) before,
        newBlock,
        if (after.isNotEmpty) after,
      ];
      result = '${parts.join('\n\n')}\n';
    } else {
      final base = original.trimRight();
      result = base.isEmpty ? '$newBlock\n' : '$base\n\n$newBlock\n';
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(result);
  }
}
