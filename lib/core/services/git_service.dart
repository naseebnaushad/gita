import 'dart:io';

/// Thin wrapper around the `git` CLI. Never reimplements plumbing that
/// `git config`, `git remote`, `git rev-parse` etc. already do (plan §2).
class GitService {
  /// [environmentOverride] lets tests isolate the subprocess from the real
  /// machine's global/system gitconfig (e.g. by pointing GIT_CONFIG_GLOBAL
  /// and GIT_CONFIG_SYSTEM at empty files) without affecting production
  /// behavior, where inheriting the real environment is exactly what we want.
  const GitService({Map<String, String>? environmentOverride})
      : _environmentOverride = environmentOverride;

  final Map<String, String>? _environmentOverride;

  Future<ProcessResult> _run(List<String> args, {String? workingDir}) {
    return Process.run(
      'git',
      args,
      workingDirectory: workingDir,
      environment: _environmentOverride,
      includeParentEnvironment: true,
    );
  }

  Future<bool> isGitRepo(String path) async {
    final result = await _run(
      ['rev-parse', '--is-inside-work-tree'],
      workingDir: path,
    );
    return result.exitCode == 0 && result.stdout.toString().trim() == 'true';
  }

  Future<String?> topLevel(String path) async {
    final result = await _run(['rev-parse', '--show-toplevel'], workingDir: path);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  }

  /// Effective `user.email`, resolved through any includeIf chain — this is
  /// git's own resolution, so we trust it rather than parsing config files
  /// ourselves (plan §6.3 step 1).
  Future<String?> getConfigValue(String path, String key) async {
    final result = await _run(['config', '--get', key], workingDir: path);
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  }

  Future<void> setConfigValue(
    String path,
    String key,
    String value, {
    bool global = false,
  }) async {
    final args = ['config', if (global) '--global', key, value];
    final result = await _run(args, workingDir: global ? null : path);
    if (result.exitCode != 0) {
      throw GitServiceException('git config $key failed: ${result.stderr}');
    }
  }

  /// First configured remote's URL, or a named remote if given.
  Future<String?> getRemoteUrl(String path, {String remote = 'origin'}) async {
    final result = await _run(['remote', 'get-url', remote], workingDir: path);
    if (result.exitCode != 0) return null;
    final value = (result.stdout as String).trim();
    return value.isEmpty ? null : value;
  }

  Future<List<String>> listRemotes(String path) async {
    final result = await _run(['remote'], workingDir: path);
    if (result.exitCode != 0) return [];
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }
}

class GitServiceException implements Exception {
  GitServiceException(this.message);
  final String message;

  @override
  String toString() => 'GitServiceException: $message';
}
