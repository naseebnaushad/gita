import 'dart:io';

import 'package:path/path.dart' as p;

import 'git_service.dart';
import 'platform_paths.dart';

enum GuardState {
  /// Both hooks are Gita's and current.
  installed,

  /// No Gita hooks (or only one of them).
  missing,

  /// Gita's hooks are there but from an older Gita.
  outdated,

  /// The project sends git to its own hooks folder (core.hooksPath, e.g.
  /// husky). Gita leaves that alone.
  customHooksPath,

  /// Not a git project.
  notARepo,
}

class GuardResult {
  const GuardResult(this.state, [this.message]);

  final GuardState state;
  final String? message;

  bool get ok => state == GuardState.installed;
}

/// Installs Gita's safety check into a project: `pre-commit` and
/// `pre-push` hooks that ask the `gita` command whether the commit or push
/// uses the right account, and stop it if not.
///
/// The hooks are short sh scripts (Git for Windows runs them with its own
/// sh). A hook the project already had is kept as `<name>.local` and still
/// runs after Gita's check. If the `gita` command is missing the hooks let
/// everything through, so uninstalling Gita never blocks anyone.
class HookService {
  HookService({required this.paths, this.git = const GitService()});

  final PlatformPaths paths;
  final GitService git;

  static const hookNames = ['pre-commit', 'pre-push'];

  /// Changes whenever the script changes, so older hooks are updated.
  static const version = 1;
  static const marker = '# Installed by Gita (gita-guard v$version)';
  static const _markerPrefix = '# Installed by Gita (gita-guard';

  /// The hooks folder for [repo], or a [GuardResult] saying why there
  /// isn't one Gita may use.
  Future<(String?, GuardResult?)> _hooksDir(String repo) async {
    final top = await git.topLevel(repo);
    if (top == null) return (null, const GuardResult(GuardState.notARepo, "This folder isn't a git project."));
    final custom = await git.getConfigValue(top, 'core.hooksPath');
    if (custom != null) {
      return (
        null,
        GuardResult(
          GuardState.customHooksPath,
          'This project runs its own hooks from "$custom", so Gita didn\'t add its '
          'check there. It still checks the account in the app and with "gita check".',
        ),
      );
    }
    final result = await git.raw(['rev-parse', '--git-path', 'hooks'], workingDir: top);
    if (result.exitCode != 0) {
      return (null, const GuardResult(GuardState.notARepo, "This folder isn't a git project."));
    }
    final dir = (result.stdout as String).trim();
    return (p.normalize(p.isAbsolute(dir) ? dir : p.join(top, dir)), null);
  }

  Future<GuardResult> status(String repo) async {
    final (dir, problem) = await _hooksDir(repo);
    if (problem != null) return problem;
    var outdated = false;
    for (final name in hookNames) {
      final file = File(p.join(dir!, name));
      if (!file.existsSync()) return const GuardResult(GuardState.missing);
      final text = _readOrEmpty(file);
      if (!text.contains(_markerPrefix)) return const GuardResult(GuardState.missing);
      if (!text.contains(marker)) outdated = true;
    }
    return GuardResult(outdated ? GuardState.outdated : GuardState.installed);
  }

  Future<GuardResult> install(String repo) async {
    final (dir, problem) = await _hooksDir(repo);
    if (problem != null) return problem;
    Directory(dir!).createSync(recursive: true);

    for (final name in hookNames) {
      final file = File(p.join(dir, name));
      if (file.existsSync() && !_readOrEmpty(file).contains(_markerPrefix)) {
        final local = File(p.join(dir, '$name.local'));
        if (local.existsSync()) {
          return GuardResult(
            GuardState.missing,
            'This project already has a "$name" hook and a "$name.local" one, '
            "so Gita didn't touch them.",
          );
        }
        file.renameSync(local.path);
      }
      file.writeAsStringSync(script(name), flush: true);
      await _makeExecutable(file.path);
    }
    return const GuardResult(GuardState.installed);
  }

  /// Removes Gita's hooks and puts back any hooks they replaced.
  Future<GuardResult> uninstall(String repo) async {
    final (dir, problem) = await _hooksDir(repo);
    if (problem != null) return problem;
    for (final name in hookNames) {
      final file = File(p.join(dir!, name));
      if (!file.existsSync() || !_readOrEmpty(file).contains(_markerPrefix)) continue;
      file.deleteSync();
      final local = File(p.join(dir, '$name.local'));
      if (local.existsSync()) local.renameSync(file.path);
    }
    return const GuardResult(GuardState.missing);
  }

  /// The hook script for [name].
  String script(String name) {
    final cli = _shQuote(paths.cliPath.replaceAll(r'\', '/'));
    final verb = name == 'pre-push' ? 'push' : 'commit';
    // pre-push gets the refs being pushed on stdin; both Gita and the
    // project's own hook need them, so it is read once and passed on.
    final readInput = name == 'pre-push' ? 'input=\$(cat)\n' : '';
    final feed = name == 'pre-push' ? 'printf \'%s\\n\' "\$input" | ' : '';
    return '''#!/bin/sh
$marker
# Stops a $verb that would use the wrong GitHub account.
# To skip this check once: git $verb --no-verify
${readInput}gita=$cli
[ -x "\$gita" ] || gita=\$(command -v gita 2>/dev/null)
if [ -n "\$gita" ]; then
  $feed"\$gita" hook $name "\$@" || exit \$?
fi
local_hook="\$(dirname "\$0")/$name.local"
if [ -x "\$local_hook" ]; then
  $feed"\$local_hook" "\$@" || exit \$?
fi
exit 0
''';
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  static String _readOrEmpty(File file) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      return '';
    } on FormatException {
      return ''; // A binary hook: not ours.
    }
  }

  static Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['+x', path]);
  }
}
