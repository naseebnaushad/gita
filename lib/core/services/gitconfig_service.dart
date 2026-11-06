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

  /// HTTPS remotes the credential helper is scoped to. Other hosts keep
  /// whatever helper the machine already uses.
  static const credentialHosts = ['https://github.com'];

  /// Writes the per-profile `[user]`/`[core]`/`[commit]` include file that
  /// each `includeIf` block in `~/.gitconfig` points at.
  ///
  /// When [useCredentialHelper] is true (the profile has a saved token) and
  /// the `gita` CLI is installed, HTTPS pushes in this profile's folders
  /// authenticate through `gita credential` with that profile's token,
  /// instead of whichever single GitHub login the machine remembers.
  Future<void> writeProfileConfigFile(
    Profile profile, {
    String? sshCommand,
    bool useCredentialHelper = false,
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
        // Quoted: the command holds a quoted key path, and git would
        // otherwise strip those quotes when reading the value.
        ..writeln('    sshCommand = ${_quoteConfigValue(sshCommand)}');
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

    if (useCredentialHelper && File(paths.cliPath).existsSync()) {
      final helper = credentialHelperCommand(profile.id);
      for (final host in credentialHosts) {
        buffer
          ..writeln('[credential "$host"]')
          // An empty value clears the helpers configured so far (system and
          // global, e.g. Git Credential Manager), so git can't fall back to
          // a cached login for a different account.
          ..writeln('    helper =')
          ..writeln('    helper = ${_quoteConfigValue(helper)}');
      }
    }

    final file = File(_profileConfigPath(profile.id));
    await file.writeAsString(buffer.toString());
  }

  /// The helper command git runs: the `!` prefix makes git run it through
  /// its shell, and the quotes keep a home folder with spaces in one piece.
  String credentialHelperCommand(String profileId) =>
      '!"${paths.toGitConfigPath(paths.cliPath)}" credential --profile $profileId';

  /// Wraps a git config value in double quotes, escaping the characters
  /// git would otherwise interpret (quotes and backslashes).
  static String _quoteConfigValue(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

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
      ..sort((a, b) => paths
          .toGitConfigPath(a.pathPattern)
          .length
          .compareTo(paths.toGitConfigPath(b.pathPattern).length));

    final block = StringBuffer()..writeln(_startMarker);
    for (final rule in sorted) {
      final profile = profilesById[rule.profileId];
      if (profile == null) continue;
      // `gitdir:` matching is forward-slash-only regardless of OS — a
      // backslash is an escape character in the fnmatch-style pattern, not
      // a separator, so a raw Windows path here would silently never
      // match. `gitdir/i:` additionally matches case-insensitively, which
      // Windows and (by default) macOS filesystems require.
      final normalizedPattern = paths.toGitConfigPath(rule.pathPattern);
      final gitDir = normalizedPattern.endsWith('/')
          ? normalizedPattern
          : '$normalizedPattern/';
      final includePath = paths.toGitConfigPath(_profileConfigPath(profile.id));
      block
        ..writeln('[includeIf "gitdir/i:$gitDir"]')
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
