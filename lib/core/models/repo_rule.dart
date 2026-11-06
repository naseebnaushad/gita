import 'dart:io';

import '../services/remote_url.dart';

/// Says which profile a project uses. Two kinds:
///
/// * a **folder rule**: every project inside [pathPattern];
/// * an **account rule** ([githubOwner] set): every project whose remote
///   is on [host] under that GitHub account or organization, wherever its
///   folder is. [pathPattern] is empty for these.
///
/// When both apply, an account rule beats a folder rule, and a rule for
/// one exact project folder beats both.
class RepoRule {
  final String id;
  final String pathPattern;
  final String profileId;
  final int priority;

  /// The GitHub account or organization for an account rule, e.g. `acme`.
  final String? githubOwner;

  /// The host for an account rule: `github.com` unless set.
  final String host;

  static const defaultHost = 'github.com';

  const RepoRule({
    required this.id,
    required this.pathPattern,
    required this.profileId,
    this.priority = 0,
    this.githubOwner,
    this.host = defaultHost,
  });

  /// Every project from `host/owner/...` uses [profileId].
  factory RepoRule.account({
    required String id,
    required String owner,
    required String profileId,
    String host = defaultHost,
  }) => RepoRule(
    id: id,
    pathPattern: '',
    profileId: profileId,
    githubOwner: owner.trim(),
    host: host.trim().toLowerCase(),
  );

  bool get isAccountRule => githubOwner != null && githubOwner!.isNotEmpty;

  /// What the rule covers, in words: a folder, or `github.com/acme`.
  String get describe => isAccountRule ? '$host/$githubOwner' : pathPattern;

  /// A folder rule for one exact project (the folder is itself a git
  /// project), as opposed to a folder that holds projects.
  bool get isProjectRule =>
      !isAccountRule &&
      pathPattern.isNotEmpty &&
      FileSystemEntity.typeSync('${_slashes(pathPattern)}/.git') !=
          FileSystemEntityType.notFound;

  factory RepoRule.fromJson(Map<String, dynamic> json) {
    return RepoRule(
      id: json['id'] as String,
      pathPattern: json['pathPattern'] as String? ?? '',
      profileId: json['profileId'] as String,
      priority: json['priority'] as int? ?? 0,
      githubOwner: json['githubOwner'] as String?,
      host: json['host'] as String? ?? defaultHost,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'pathPattern': pathPattern,
    'profileId': profileId,
    'priority': priority,
    if (githubOwner != null) 'githubOwner': githubOwner,
    if (host != defaultHost) 'host': host,
  };

  /// True when [remoteUrl] is on this account rule's host and owner.
  /// Owner names compare without regard to case, as GitHub does.
  bool coversRemote(String remoteUrl) {
    if (!isAccountRule) return false;
    final r = RemoteUrl.parse(remoteUrl);
    if (r == null || r.host != host.toLowerCase()) return false;
    return r.topOwner?.toLowerCase() == githubOwner!.toLowerCase();
  }

  /// The order Gita writes rules into ~/.gitconfig, where the last match
  /// wins: folder rules (shortest first), then account rules, then rules
  /// for single projects. [bestMatchFor] follows the same order.
  static List<RepoRule> inEmitOrder(List<RepoRule> rules) {
    int len(RepoRule r) => _slashes(r.pathPattern).length;
    final folders = <RepoRule>[];
    final accounts = <RepoRule>[];
    final projects = <RepoRule>[];
    for (final r in rules) {
      if (r.isAccountRule) {
        accounts.add(r);
      } else if (r.pathPattern.isEmpty) {
        continue;
      } else if (r.isProjectRule) {
        projects.add(r);
      } else {
        folders.add(r);
      }
    }
    folders.sort((a, b) => len(a).compareTo(len(b)));
    projects.sort((a, b) => len(a).compareTo(len(b)));
    accounts.sort((a, b) {
      final c = a.githubOwner!.toLowerCase().compareTo(
        b.githubOwner!.toLowerCase(),
      );
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return [...folders, ...accounts, ...projects];
  }

  /// Which rule decides the profile for the project at [repoPath].
  ///
  /// A rule for this exact project folder wins. Otherwise an account rule
  /// for one of the project's [remoteUrls]. Otherwise the longest folder
  /// rule (explicit priority is the tiebreaker).
  ///
  /// Both sides are normalized to forward slashes before comparing: rules
  /// created before this normalization was added may still have
  /// backslash-separated `pathPattern`s on Windows, and comparing those
  /// raw against a forward-slash repo path (as `git rev-parse
  /// --show-toplevel` always returns) would silently never match.
  static RepoRule? bestMatchFor(
    String repoPath,
    List<RepoRule> rules, {
    List<String> remoteUrls = const [],
  }) {
    final normalizedRepo = _withTrailingSlash(_slashes(repoPath));
    final folderRules = rules
        .where((r) => !r.isAccountRule && r.pathPattern.isNotEmpty)
        .toList();

    final exact = folderRules.where(
      (r) =>
          _withTrailingSlash(_slashes(r.pathPattern)).toLowerCase() ==
          normalizedRepo.toLowerCase(),
    );
    if (exact.isNotEmpty) {
      return exact.reduce((a, b) => b.priority > a.priority ? b : a);
    }

    if (remoteUrls.isNotEmpty) {
      // Git applies every matching include and the last one wins.
      final accounts = inEmitOrder(
        rules.where((r) => r.isAccountRule).toList(),
      );
      for (final rule in accounts.reversed) {
        if (remoteUrls.any(rule.coversRemote)) return rule;
      }
    }

    final matches = folderRules.where((r) {
      final pattern = _withTrailingSlash(_slashes(r.pathPattern));
      return normalizedRepo.startsWith(pattern);
    }).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final aLen = _slashes(a.pathPattern).length;
      final bLen = _slashes(b.pathPattern).length;
      final lenCompare = bLen.compareTo(aLen);
      if (lenCompare != 0) return lenCompare;
      return b.priority.compareTo(a.priority);
    });
    return matches.first;
  }

  static String _slashes(String path) => path.replaceAll('\\', '/');

  static String _withTrailingSlash(String path) =>
      path.endsWith('/') ? path : '$path/';
}
