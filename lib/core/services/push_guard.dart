import '../models/profile.dart';
import '../models/repo_rule.dart';
import 'git_service.dart';
import 'path_resolver.dart';

/// A commit about to be pushed that was made with the wrong email.
class WrongCommit {
  const WrongCommit(this.sha, this.email, this.subject);

  final String sha;
  final String email;
  final String subject;
}

class GuardVerdict {
  const GuardVerdict.allow()
      : allowed = true,
        profile = null,
        configuredEmail = null,
        wrongCommits = const [],
        rebaseBase = null;

  const GuardVerdict.block({
    required this.profile,
    required this.configuredEmail,
    this.wrongCommits = const [],
    this.rebaseBase,
  }) : allowed = false;

  final bool allowed;

  /// The profile the project belongs to.
  final Profile? profile;

  /// The email git would commit with right now.
  final String? configuredEmail;

  /// For a push: the commits made with another email.
  final List<WrongCommit> wrongCommits;

  /// For a push: what to rebase onto to fix [wrongCommits], or `--root`.
  final String? rebaseBase;
}

/// The checks behind Gita's pre-commit and pre-push hooks. Only a wrong
/// email blocks; a project no rule covers is let through, so the hooks
/// never get in the way of projects Gita doesn't manage.
class PushGuard {
  const PushGuard({this.git = const GitService()});

  final GitService git;

  static const _zero = '0000000000000000000000000000000000000000';

  Future<Profile?> expectedProfile(String repo, List<Profile> profiles, List<RepoRule> rules) async {
    final top = await git.topLevel(repo);
    if (top == null) return null;
    final rule = RepoRule.bestMatchFor(resolveRepoPath(top), rules);
    if (rule == null) return null;
    return profiles.where((p) => p.id == rule.profileId).firstOrNull;
  }

  Future<GuardVerdict> checkCommit(String repo, List<Profile> profiles, List<RepoRule> rules) async {
    final profile = await expectedProfile(repo, profiles, rules);
    if (profile == null) return const GuardVerdict.allow();
    final email = await git.getConfigValue(repo, 'user.email');
    // No email at all: git itself refuses the commit with its own message.
    if (email == null || _same(email, profile.gitEmail)) return const GuardVerdict.allow();
    return GuardVerdict.block(profile: profile, configuredEmail: email);
  }

  /// [refLines] is what git gives a pre-push hook on stdin: one
  /// `<local ref> <local sha> <remote ref> <remote sha>` line per ref.
  Future<GuardVerdict> checkPush(
    String repo,
    List<Profile> profiles,
    List<RepoRule> rules,
    String refLines,
  ) async {
    final profile = await expectedProfile(repo, profiles, rules);
    if (profile == null) return const GuardVerdict.allow();

    final wrong = <String, WrongCommit>{};
    String? base;
    for (final line in refLines.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final localSha = parts[1];
      final remoteSha = parts[3];
      if (localSha == _zero) continue; // Deleting a branch.

      final known = remoteSha != _zero && await _exists(repo, remoteSha);
      final commits = await _newCommits(repo, localSha, known ? remoteSha : null);
      for (final c in commits) {
        if (!_same(c.email, profile.gitEmail)) wrong[c.sha] = c;
      }
      if (commits.isNotEmpty && commits.any((c) => !_same(c.email, profile.gitEmail))) {
        base ??= known ? remoteSha : await _parentOf(repo, commits.last.sha);
      }
    }
    if (wrong.isEmpty) return const GuardVerdict.allow();
    return GuardVerdict.block(
      profile: profile,
      configuredEmail: await git.getConfigValue(repo, 'user.email'),
      wrongCommits: wrong.values.toList(),
      rebaseBase: base,
    );
  }

  /// Commits reachable from [localSha] that no remote has yet, newest
  /// first. Commits teammates already pushed are never counted.
  Future<List<WrongCommit>> _newCommits(String repo, String localSha, String? remoteSha) async {
    final result = await git.raw([
      'log',
      '--format=%H%x09%ae%x09%s',
      localSha,
      '--not',
      ?remoteSha,
      '--remotes',
    ], workingDir: repo);
    if (result.exitCode != 0) return const [];
    return [
      for (final line in (result.stdout as String).split('\n'))
        if (line.trim().isNotEmpty) _parse(line),
    ];
  }

  WrongCommit _parse(String line) {
    final parts = line.split('\t');
    return WrongCommit(parts[0], parts.length > 1 ? parts[1] : '', parts.length > 2 ? parts.sublist(2).join('\t').trim() : '');
  }

  Future<bool> _exists(String repo, String sha) async =>
      (await git.raw(['cat-file', '-e', '$sha^{commit}'], workingDir: repo)).exitCode == 0;

  Future<String> _parentOf(String repo, String sha) async {
    final result = await git.raw(['rev-parse', '--verify', '--quiet', '$sha^'], workingDir: repo);
    final parent = (result.stdout as String).trim();
    return result.exitCode == 0 && parent.isNotEmpty ? parent : '--root';
  }

  static bool _same(String a, String b) => a.trim().toLowerCase() == b.trim().toLowerCase();
}
