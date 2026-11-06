import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/ssh_key.dart';
import 'git_service.dart';
import 'path_resolver.dart';
import 'platform_paths.dart';

/// A git project found on this computer.
class ScannedRepo {
  const ScannedRepo({
    required this.path,
    this.remoteUrls = const [],
    this.localEmail,
    this.localName,
    this.usedEmail,
    this.usedName,
  });

  /// Canonical forward-slash path (see [resolveRepoPath]).
  final String path;
  final List<String> remoteUrls;

  /// `user.email` / `user.name` set inside the project itself.
  final String? localEmail;
  final String? localName;

  /// The identity this computer has been committing with in the project,
  /// from its reflog (so other people's commits don't count).
  final String? usedEmail;
  final String? usedName;

  /// The email this project's commits use: its own setting first, then the
  /// one it has been used with.
  String? get email => localEmail ?? usedEmail;

  String? get name => localName ?? usedName;

  /// SSH host aliases its remotes go through (`git@github-work:org/x` →
  /// `github-work`).
  Iterable<String> get sshHosts sync* {
    for (final url in remoteUrls) {
      final host = sshHostOf(url);
      if (host != null) yield host;
    }
  }

  Map<String, Object?> toJson() => {
        'path': path,
        'remotes': remoteUrls,
        if (localEmail != null) 'localEmail': localEmail,
        if (usedEmail != null) 'usedEmail': usedEmail,
      };
}

/// An SSH key pair found in `~/.ssh`.
class FoundSshKey {
  const FoundSshKey({required this.privateKeyPath, required this.publicKeyPath, this.comment});

  final String privateKeyPath;
  final String publicKeyPath;

  /// The text after the key in the `.pub` file, often an email.
  final String? comment;

  String get fileName => p.basename(privateKeyPath);

  Map<String, Object?> toJson() => {
        'path': privateKeyPath,
        if (comment != null) 'comment': comment,
      };
}

/// A profile Gita suggests making, from an identity found on this computer.
class ProfileSuggestion {
  ProfileSuggestion({
    required this.email,
    required this.name,
    required this.label,
    required this.repos,
    required this.folders,
    this.sshKey,
    this.githubLogin,
    this.isGlobalDefault = false,
    this.existingProfileId,
  });

  final String email;
  final String name;
  final String label;

  /// Projects that use this email.
  final List<ScannedRepo> repos;

  /// Folders to assign to the profile: a whole parent folder when every
  /// project in it uses this email, otherwise the projects themselves.
  final List<String> folders;

  /// The key this identity seems to push with, if one was found.
  final FoundSshKey? sshKey;

  /// From a GitHub "noreply" email, if it is one.
  final String? githubLogin;

  /// The identity in `~/.gitconfig`, used where no rule applies.
  final bool isGlobalDefault;

  /// Set when a Gita profile with this email exists already.
  final String? existingProfileId;

  Map<String, Object?> toJson() => {
        'label': label,
        'name': name,
        'email': email,
        if (githubLogin != null) 'githubLogin': githubLogin,
        'globalDefault': isGlobalDefault,
        if (existingProfileId != null) 'existingProfile': existingProfileId,
        'sshKey': sshKey?.privateKeyPath,
        'folders': folders,
        'projects': repos.map((r) => r.path).toList(),
      };
}

/// Everything [MachineScanner.scan] found.
class MachineScan {
  const MachineScan({
    required this.searchedFolders,
    required this.repos,
    required this.sshKeys,
    required this.suggestions,
    this.globalName,
    this.globalEmail,
  });

  final List<String> searchedFolders;
  final List<ScannedRepo> repos;
  final List<FoundSshKey> sshKeys;
  final List<ProfileSuggestion> suggestions;
  final String? globalName;
  final String? globalEmail;

  /// Projects whose email couldn't be worked out.
  List<ScannedRepo> get unknownRepos => [for (final r in repos) if (r.email == null) r];

  Map<String, Object?> toJson() => {
        'searched': searchedFolders,
        if (globalEmail != null) 'globalIdentity': {'name': globalName, 'email': globalEmail},
        'profiles': suggestions.map((s) => s.toJson()).toList(),
        'sshKeys': sshKeys.map((k) => k.toJson()).toList(),
        'projectsWithoutEmail': unknownRepos.map((r) => r.path).toList(),
      };
}

/// `git@host:org/repo`, `ssh://git@host/org/repo` → `host`; null for HTTPS.
String? sshHostOf(String url) {
  final scp = RegExp(r'^(?:[^@/\s]+@)?([^:/\s]+):(?!//)').firstMatch(url);
  // A single letter before the colon is a Windows drive (C:/code), not a host.
  if (scp != null && !url.contains('://') && scp.group(1)!.length > 1) return scp.group(1);
  final ssh = RegExp(r'^ssh://(?:[^@/]+@)?([^/:]+)').firstMatch(url);
  return ssh?.group(1);
}

/// The GitHub login in a GitHub "noreply" email, e.g.
/// `12345+octo@users.noreply.github.com` → `octo`.
String? githubLoginFromEmail(String email) {
  final m = RegExp(r'^(?:\d+\+)?([A-Za-z0-9-]+)@users\.noreply\.github\.com$',
          caseSensitive: false)
      .firstMatch(email.trim());
  return m?.group(1);
}

const _personalDomains = {
  'gmail.com',
  'googlemail.com',
  'outlook.com',
  'hotmail.com',
  'live.com',
  'yahoo.com',
  'icloud.com',
  'me.com',
  'proton.me',
  'protonmail.com',
  'users.noreply.github.com',
};

/// A short profile name for [email]: "Personal" for well-known personal
/// mail services, otherwise the company part of the domain ("Thoughtbox").
String suggestLabel(String email) {
  final at = email.lastIndexOf('@');
  if (at < 0) return 'Profile';
  final domain = email.substring(at + 1).toLowerCase();
  if (_personalDomains.contains(domain) || domain.endsWith('.noreply.github.com')) {
    return 'Personal';
  }
  final parts = domain.split('.');
  // mail.company.co.uk → company
  final name = parts.length >= 3 && parts[parts.length - 2].length <= 3
      ? parts[parts.length - 3]
      : (parts.length >= 2 ? parts[parts.length - 2] : parts.first);
  if (name.isEmpty) return 'Work';
  return name[0].toUpperCase() + name.substring(1);
}

/// Looks around this computer for git projects, the identities they
/// commit with, and SSH keys, and suggests profiles and folder rules from
/// them. Reads only; nothing is changed.
class MachineScanner {
  MachineScanner({
    required this.paths,
    this.git = const GitService(),
    this.maxDepth = 4,
    this.maxRepos = 400,
  });

  final PlatformPaths paths;
  final GitService git;

  /// How many folders deep to look under each search folder.
  final int maxDepth;

  /// Stop after this many projects, so a huge disk can't stall the scan.
  final int maxRepos;

  /// Where people usually keep code, relative to the home folder.
  static const commonCodeFolders = [
    'StudioProjects',
    'AndroidStudioProjects',
    'IdeaProjects',
    'source/repos',
    'Projects',
    'projects',
    'Code',
    'code',
    'dev',
    'Dev',
    'Development',
    'git',
    'Git',
    'GitHub',
    'Documents/GitHub',
    'Documents/Projects',
    'repos',
    'src',
    'workspace',
    'Workspace',
    'work',
    'Work',
    'Sites',
    'go/src',
    'Desktop',
  ];

  static const _skipDirs = {
    'node_modules',
    'build',
    'dist',
    'target',
    'vendor',
    'Pods',
    'venv',
    '__pycache__',
    'AppData',
    'Library',
  };

  /// The default folders [scan] looks in: the common code folders that
  /// exist on this computer.
  List<String> defaultSearchFolders() {
    final home = paths.homeDir();
    final seen = <String>{};
    final found = <String>[];
    for (final rel in commonCodeFolders) {
      final dir = Directory(p.join(home, rel));
      if (!dir.existsSync()) continue;
      final canonical = resolveRepoPath(dir.path);
      // Case-insensitive file systems list Code and code twice.
      if (seen.add(canonical.toLowerCase())) found.add(canonical);
    }
    return found;
  }

  Future<MachineScan> scan({
    List<String>? searchFolders,
    List<Profile> existingProfiles = const [],
  }) async {
    final folders = searchFolders ?? defaultSearchFolders();
    final repoPaths = <String>{};
    for (final folder in folders) {
      if (repoPaths.length >= maxRepos) break;
      _findRepos(Directory(folder), 0, repoPaths);
    }
    final repos = await _inspectAll(repoPaths.toList()..sort());
    final globalEmail = await _globalConfig('user.email');
    final globalName = await _globalConfig('user.name');
    final keys = findSshKeys();
    final aliases = readSshConfigIdentities();

    return MachineScan(
      searchedFolders: folders,
      repos: repos,
      sshKeys: keys,
      globalEmail: globalEmail,
      globalName: globalName,
      suggestions: suggest(
        repos: repos,
        keys: keys,
        sshAliases: aliases,
        globalEmail: globalEmail,
        globalName: globalName,
        existingProfiles: existingProfiles,
        searchFolders: folders,
        homeDir: paths.homeDir(),
      ),
    );
  }

  void _findRepos(Directory dir, int depth, Set<String> found) {
    if (found.length >= maxRepos) return;
    final List<FileSystemEntity> children;
    try {
      children = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    if (children.any((e) => p.basename(e.path) == '.git')) {
      found.add(resolveRepoPath(dir.path));
      return; // Nested projects are usually submodules or vendored copies.
    }
    if (depth >= maxDepth) return;
    for (final child in children) {
      if (child is! Directory) continue;
      final name = p.basename(child.path);
      if (name.startsWith('.') || _skipDirs.contains(name)) continue;
      _findRepos(child, depth + 1, found);
    }
  }

  Future<List<ScannedRepo>> _inspectAll(List<String> paths) async {
    final results = List<ScannedRepo?>.filled(paths.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < paths.length) {
        final i = next++;
        results[i] = await inspectRepo(paths[i]);
      }
    }

    await Future.wait([for (var i = 0; i < 6; i++) worker()]);
    return results.whereType<ScannedRepo>().toList();
  }

  /// Reads one project's remotes and the identity it is used with.
  Future<ScannedRepo> inspectRepo(String path) async {
    Future<String?> local(String key) async {
      final r = await git.raw(['config', '--local', '--get', key], workingDir: path);
      final v = r.exitCode == 0 ? (r.stdout as String).trim() : '';
      return v.isEmpty ? null : v;
    }

    final remotes = await git.raw(['config', '--local', '--get-regexp', r'^remote\..*\.url$'],
        workingDir: path);
    final urls = remotes.exitCode == 0
        ? (remotes.stdout as String)
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .map((l) => l.substring(l.indexOf(' ') + 1).trim())
            .toSet()
            .toList()
        : <String>[];

    // The reflog records who did each commit, checkout or pull on this
    // computer, so it tells us which identity this person uses here.
    final reflog = await git.raw(
      ['log', '-g', '-n', '40', '--format=%gE%x09%gN', 'HEAD'],
      workingDir: path,
    );
    final counts = <String, int>{};
    final names = <String, String>{};
    if (reflog.exitCode == 0) {
      for (final line in (reflog.stdout as String).split('\n')) {
        final parts = line.trim().split('\t');
        final email = parts.first.trim();
        if (email.isEmpty || !email.contains('@') || _isServiceEmail(email)) continue;
        final key = email.toLowerCase();
        counts[key] = (counts[key] ?? 0) + 1;
        if (parts.length > 1 && parts[1].trim().isNotEmpty) names[key] = parts[1].trim();
      }
    }
    String? used;
    if (counts.isNotEmpty) {
      used = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    }

    return ScannedRepo(
      path: path,
      remoteUrls: urls,
      localEmail: await local('user.email'),
      localName: await local('user.name'),
      usedEmail: used,
      usedName: used == null ? null : names[used],
    );
  }

  static bool _isServiceEmail(String email) {
    final e = email.toLowerCase();
    return e == 'noreply@github.com' || e.startsWith('noreply@') || e.endsWith('@localhost');
  }

  Future<String?> _globalConfig(String key) async {
    final r = await git.raw(['config', '--global', '--get', key]);
    final v = r.exitCode == 0 ? (r.stdout as String).trim() : '';
    return v.isEmpty ? null : v;
  }

  /// SSH key pairs in `~/.ssh` (a private key with a matching `.pub`).
  List<FoundSshKey> findSshKeys() {
    final dir = Directory(p.join(paths.homeDir(), '.ssh'));
    if (!dir.existsSync()) return const [];
    final keys = <FoundSshKey>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.pub')) continue;
      final private = entity.path.substring(0, entity.path.length - 4);
      if (!File(private).existsSync()) continue;
      String? comment;
      try {
        final fields = entity.readAsStringSync().trim().split(RegExp(r'\s+'));
        if (fields.length >= 3) comment = fields.sublist(2).join(' ');
      } on FileSystemException {
        // Unreadable; list it without a comment.
      }
      keys.add(FoundSshKey(privateKeyPath: private, publicKeyPath: entity.path, comment: comment));
    }
    keys.sort((a, b) => a.privateKeyPath.compareTo(b.privateKeyPath));
    return keys;
  }

  /// `Host` aliases in `~/.ssh/config` and the key file each one uses.
  Map<String, String> readSshConfigIdentities() {
    final file = File(paths.sshConfigPath);
    if (!file.existsSync()) return const {};
    final result = <String, String>{};
    var hosts = <String>[];
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final m = RegExp(r'^(\w+)\s*=?\s*(.+)$').firstMatch(line);
      if (m == null) continue;
      final key = m.group(1)!.toLowerCase();
      final value = m.group(2)!.trim();
      if (key == 'host') {
        hosts = value.split(RegExp(r'\s+')).where((h) => !h.contains('*')).toList();
      } else if (key == 'match') {
        hosts = [];
      } else if (key == 'identityfile') {
        var path = value.replaceAll('"', '');
        if (path.startsWith('~')) path = p.join(paths.homeDir(), path.substring(2));
        for (final h in hosts) {
          result.putIfAbsent(h, () => p.normalize(path));
        }
      }
    }
    return result;
  }

  /// Groups [repos] by the email they use and suggests a profile for each
  /// one, plus the global identity even if no project uses it.
  static List<ProfileSuggestion> suggest({
    required List<ScannedRepo> repos,
    List<FoundSshKey> keys = const [],
    Map<String, String> sshAliases = const {},
    String? globalEmail,
    String? globalName,
    List<Profile> existingProfiles = const [],
    List<String> searchFolders = const [],
    String? homeDir,
  }) {
    final byEmail = <String, List<ScannedRepo>>{};
    final displayEmail = <String, String>{};
    final nameFor = <String, String>{};
    for (final repo in repos) {
      final email = repo.email;
      if (email == null) continue;
      final key = email.toLowerCase();
      byEmail.putIfAbsent(key, () => []).add(repo);
      displayEmail.putIfAbsent(key, () => email);
      if (repo.name != null) nameFor.putIfAbsent(key, () => repo.name!);
    }
    final globalKey = globalEmail?.toLowerCase();
    if (globalKey != null) {
      byEmail.putIfAbsent(globalKey, () => []);
      displayEmail[globalKey] = globalEmail!;
      if (globalName != null) nameFor[globalKey] = globalName;
    }

    // Which email each project folder belongs to, to tell whether a whole
    // parent folder can be given to one profile.
    final emailOf = {for (final r in repos) r.path: r.email?.toLowerCase()};
    final searchRoots = {for (final f in searchFolders) _norm(f)};
    final home = _norm(homeDir ?? const PlatformPaths().homeDir());

    final keyByPath = {for (final k in keys) p.normalize(k.privateKeyPath).toLowerCase(): k};
    final usedLabels = <String>{for (final pr in existingProfiles) pr.label.toLowerCase()};

    final order = byEmail.keys.toList()
      ..sort((a, b) {
        if (a == globalKey) return -1;
        if (b == globalKey) return 1;
        return byEmail[b]!.length.compareTo(byEmail[a]!.length);
      });

    final suggestions = <ProfileSuggestion>[];
    for (final key in order) {
      final email = displayEmail[key]!;
      final mine = byEmail[key]!;
      final existing = existingProfiles.where((pr) => pr.gitEmail.toLowerCase() == key);

      var label = suggestLabel(email);
      if (existing.isNotEmpty) {
        label = existing.first.label;
      } else {
        final base = label;
        for (var n = 2; usedLabels.contains(label.toLowerCase()); n++) {
          label = '$base $n';
        }
        usedLabels.add(label.toLowerCase());
      }

      suggestions.add(ProfileSuggestion(
        email: email,
        name: nameFor[key] ?? globalName ?? email.split('@').first,
        label: label,
        repos: mine,
        folders: _foldersFor(mine, key, emailOf, searchRoots, home),
        sshKey: _keyFor(email, mine, keys, sshAliases, keyByPath),
        githubLogin: githubLoginFromEmail(email),
        isGlobalDefault: key == globalKey,
        existingProfileId: existing.isEmpty ? null : existing.first.id,
      ));
    }
    return suggestions;
  }

  static String _norm(String path) {
    var s = path.replaceAll('\\', '/');
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s.toLowerCase();
  }

  static List<String> _foldersFor(
    List<ScannedRepo> mine,
    String email,
    Map<String, String?> emailOf,
    Set<String> searchRoots,
    String home,
  ) {
    final folders = <String>{};
    for (final repo in mine) {
      final parent = p.posix.dirname(repo.path);
      final parentKey = _norm(parent);
      // Never hand out the home folder or a whole drive.
      final tooBroad = parentKey == home ||
          parentKey.split('/').where((s) => s.isNotEmpty).length < 2;
      // A search root ("StudioProjects") often mixes accounts; only use it
      // if everything in it is this account's.
      final siblings = emailOf.entries
          .where((e) => _norm(p.posix.dirname(e.key)) == parentKey)
          .map((e) => e.value);
      final allMine = siblings.every((e) => e == email);
      if (!tooBroad && allMine && siblings.length > 1) {
        folders.add(parent);
      } else if (!tooBroad && allMine && !searchRoots.contains(parentKey) &&
          siblings.length == 1) {
        // The only project in a folder of its own, e.g. ~/work/acme/app.
        folders.add(parent);
      } else {
        folders.add(repo.path);
      }
    }
    final sorted = folders.toList()..sort();
    // Drop a folder already inside another one in the list.
    return [
      for (final f in sorted)
        if (!sorted.any((o) => o != f && _norm(f).startsWith('${_norm(o)}/'))) f,
    ];
  }

  static FoundSshKey? _keyFor(
    String email,
    List<ScannedRepo> mine,
    List<FoundSshKey> keys,
    Map<String, String> sshAliases,
    Map<String, FoundSshKey> keyByPath,
  ) {
    // A host alias the projects push through says it most clearly.
    for (final repo in mine) {
      for (final host in repo.sshHosts) {
        final file = sshAliases[host];
        if (file == null) continue;
        final key = keyByPath[p.normalize(file).toLowerCase()];
        if (key != null) return key;
      }
    }
    // Otherwise a key whose comment is this email.
    for (final key in keys) {
      if (key.comment?.toLowerCase().trim() == email.toLowerCase()) return key;
    }
    return null;
  }
}

/// What the setup wizard creates from the suggestions the person kept.
class SetupChoice {
  SetupChoice({
    required this.label,
    required this.name,
    required this.email,
    required this.folders,
    this.sshKey,
    this.githubLogin,
    this.existingProfileId,
    this.projects = const [],
  });

  factory SetupChoice.from(ProfileSuggestion s) => SetupChoice(
        label: s.label,
        name: s.name,
        email: s.email,
        folders: [...s.folders],
        sshKey: s.sshKey,
        githubLogin: s.githubLogin,
        existingProfileId: s.existingProfileId,
        projects: [for (final r in s.repos) r.path],
      );

  String label;
  String name;
  String email;
  List<String> folders;
  FoundSshKey? sshKey;
  String? githubLogin;
  String? existingProfileId;

  /// Projects to add to the Dashboard (with the safety check).
  List<String> projects;
}

/// The records [SetupChoice]s turn into; the caller saves them.
class SetupPlan {
  const SetupPlan({
    required this.profiles,
    required this.sshKeys,
    required this.rules,
    required this.projects,
  });

  final List<Profile> profiles;
  final List<SshKey> sshKeys;
  final List<RepoRule> rules;
  final List<String> projects;

  /// Builds the records for [choices], reusing SSH key records and rules
  /// that exist already so running setup twice doesn't duplicate them.
  static SetupPlan build({
    required List<SetupChoice> choices,
    required List<SshKey> existingKeys,
    required List<RepoRule> existingRules,
    required List<Profile> existingProfiles,
    required List<int> palette,
    required String Function() newId,
    DateTime? now,
  }) {
    final time = now ?? DateTime.now();
    final profiles = <Profile>[];
    final keys = <SshKey>[];
    final rules = <RepoRule>[];
    final projects = <String>{};
    final rulePatterns = {for (final r in existingRules) _norm(r.pathPattern)};
    var colorIndex = existingProfiles.length;

    for (final c in choices) {
      String? keyId;
      final found = c.sshKey;
      if (found != null) {
        final known = [...existingKeys, ...keys].where(
            (k) => p.normalize(k.privateKeyPath).toLowerCase() ==
                p.normalize(found.privateKeyPath).toLowerCase());
        if (known.isNotEmpty) {
          keyId = known.first.id;
        } else {
          final key = SshKey(
            id: newId(),
            label: c.label,
            privateKeyPath: found.privateKeyPath,
            publicKeyPath: found.publicKeyPath,
            hostAlias: 'github.com',
            realHost: 'github.com',
            createdAt: time,
          );
          keys.add(key);
          keyId = key.id;
        }
      }

      final existing = existingProfiles.where((pr) => pr.id == c.existingProfileId);
      final Profile profile;
      if (existing.isNotEmpty) {
        final old = existing.first;
        profile = old.copyWith(
          sshKeyId: old.sshKeyId ?? keyId,
          githubLogin: old.githubLogin ?? c.githubLogin,
        );
      } else {
        profile = Profile(
          id: newId(),
          label: c.label.trim().isEmpty ? suggestLabel(c.email) : c.label.trim(),
          gitName: c.name.trim(),
          gitEmail: c.email.trim(),
          sshKeyId: keyId,
          githubLogin: c.githubLogin,
          colorArgb: palette[colorIndex++ % palette.length],
          createdAt: time,
        );
      }
      profiles.add(profile);

      for (final folder in c.folders) {
        if (!rulePatterns.add(_norm(folder))) continue;
        rules.add(RepoRule(id: newId(), pathPattern: folder, profileId: profile.id));
      }
      projects.addAll(c.projects);
    }
    return SetupPlan(profiles: profiles, sshKeys: keys, rules: rules, projects: projects.toList());
  }

  static String _norm(String path) {
    var s = path.replaceAll('\\', '/').toLowerCase();
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
