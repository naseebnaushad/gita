import 'dart:convert';
import 'dart:io';

import '../models/repo_rule.dart';

/// Thin wrapper around the `git` CLI. Never reimplements plumbing that
/// `git config`, `git remote`, `git rev-parse` etc. already do (plan §2).
class GitService {
  /// [environmentOverride] lets tests isolate the subprocess from the real
  /// machine's global/system gitconfig (e.g. by pointing GIT_CONFIG_GLOBAL
  /// and GIT_CONFIG_SYSTEM at empty files) without affecting production
  /// behavior, where inheriting the real environment is exactly what we want.
  const GitService({this._environmentOverride});

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

  /// Starts a long-running git command (like `clone`) whose output the
  /// caller streams.
  Future<Process> start(List<String> args, {String? workingDir, Map<String, String>? environment}) {
    return Process.start(
      'git',
      args,
      workingDirectory: workingDir,
      environment: {...?_environmentOverride, ...?environment},
      includeParentEnvironment: true,
    );
  }

  /// Runs any git command. For callers that need output this class has no
  /// dedicated method for.
  Future<ProcessResult> raw(List<String> args, {String? workingDir}) =>
      _run(args, workingDir: workingDir);

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

  /// Every remote address the project has (`remote.<name>.url`, the
  /// same values git's `hasconfig:remote.*.url:` looks at).
  Future<List<String>> remoteUrls(String path) async {
    final result = await _run([
      'config',
      '--get-regexp',
      r'^remote\..*\.url$',
    ], workingDir: path);
    if (result.exitCode != 0) return const [];
    return [
      for (final line in LineSplitter.split(result.stdout as String))
        if (line.trim().contains(' '))
          line.trim().substring(line.trim().indexOf(' ') + 1).trim(),
    ];
  }

  /// The rule that decides the profile for the project at [path],
  /// looking at its remotes too so account rules apply.
  Future<RepoRule?> ruleFor(String path, List<RepoRule> rules) async {
    final urls = rules.any((r) => r.isAccountRule)
        ? await remoteUrls(path)
        : const <String>[];
    return RepoRule.bestMatchFor(path, rules, remoteUrls: urls);
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
