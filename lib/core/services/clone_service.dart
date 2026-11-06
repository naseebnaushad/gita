import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/tracked_repo.dart';
import '../storage/repositories.dart';
import 'git_config_sync.dart';
import 'git_service.dart';
import 'gitconfig_service.dart';
import 'hook_service.dart';
import 'machine_scanner.dart';
import 'path_resolver.dart';
import 'platform_paths.dart';

/// What happened when Gita cloned a project.
class CloneOutcome {
  const CloneOutcome({
    required this.ok,
    required this.path,
    required this.message,
    this.addedRule = false,
    this.guardAdded = false,
    this.guardProblem,
  });

  final bool ok;

  /// Where the project is (or would have been).
  final String path;

  /// One plain sentence or two saying what happened, or what to do.
  final String message;

  /// True when Gita added a folder rule so the project uses the profile.
  final bool addedRule;
  final bool guardAdded;
  final String? guardProblem;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'path': path,
        'message': message,
        'addedRule': addedRule,
        'safetyCheck': guardAdded,
        if (guardProblem != null) 'safetyCheckProblem': guardProblem,
      };
}

/// Clones a project with a chosen profile's GitHub sign-in and SSH key,
/// then makes sure it keeps using that profile: a folder rule if none
/// covers it, the safety check, and a place on the Dashboard.
///
/// Shared by the app and `gita clone`.
class CloneService {
  CloneService({required this.paths, this.git = const GitService()});

  final PlatformPaths paths;
  final GitService git;

  static final _scpLike = RegExp(r'^[\w.-]+@([\w.-]+):(.+)$');

  /// True for the addresses people copy from GitHub's green Code button
  /// (and other hosts): https://, ssh://, git@host:path, or a local path.
  static bool looksLikeGitUrl(String url) {
    final u = url.trim();
    if (u.isEmpty || u.contains(' ')) return false;
    if (_scpLike.hasMatch(u)) return true;
    final uri = Uri.tryParse(u);
    return uri != null &&
        const {'https', 'http', 'ssh', 'git', 'file'}.contains(uri.scheme) &&
        (uri.host.isNotEmpty || uri.scheme == 'file') &&
        uri.path.replaceAll('/', '').isNotEmpty;
  }

  /// The address's path without the host, e.g. `acme/api.git`.
  static String? _pathOf(String url) {
    final u = url.trim();
    final scp = _scpLike.firstMatch(u);
    if (scp != null) return scp.group(2);
    final uri = Uri.tryParse(u);
    if (uri == null || uri.path.isEmpty) return null;
    return uri.path;
  }

  /// The folder name git would use: the last part without `.git`.
  static String? repoNameFromUrl(String url) {
    final path = _pathOf(url)?.replaceAll('\\', '/');
    if (path == null) return null;
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var name = parts.last;
    if (name.toLowerCase().endsWith('.git')) name = name.substring(0, name.length - 4);
    return name.isEmpty ? null : name;
  }

  /// The account or organization part, e.g. `acme` in `github.com/acme/api`.
  static String? ownerFromUrl(String url) {
    final path = _pathOf(url);
    if (path == null) return null;
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    return parts.length >= 2 ? parts[parts.length - 2] : null;
  }

  static bool isSshUrl(String url) {
    final u = url.trim();
    return _scpLike.hasMatch(u) || u.startsWith('ssh://');
  }

  /// The profile whose GitHub account owns the project, if one does.
  static Profile? suggestProfile(String url, List<Profile> profiles) {
    final owner = ownerFromUrl(url)?.toLowerCase();
    if (owner == null) return null;
    for (final profile in profiles) {
      if (profile.githubLogin?.toLowerCase() == owner) return profile;
    }
    return null;
  }

  /// Where a project for [profile] should go: the profile's first rule
  /// folder that exists, else the first usual project folder, else home.
  String parentFolderFor(Profile? profile, List<RepoRule> rules) {
    if (profile != null) {
      final folders = [
        for (final r in rules)
          if (r.profileId == profile.id) r.pathPattern.replaceAll('\\', '/'),
      ]..sort((a, b) => a.length.compareTo(b.length));
      for (final f in folders) {
        // A rule for a single project is not a folder to clone into.
        if (Directory(f).existsSync() && !Directory(p.join(f, '.git')).existsSync()) {
          return f;
        }
      }
    }
    final usual = MachineScanner(paths: paths, git: git).defaultSearchFolders();
    return usual.isNotEmpty ? usual.first : resolveRepoPath(paths.homeDir());
  }

  /// Clones [url] into [destination] as [profile]. [onProgress] gets git's
  /// progress lines ("Receiving objects: 45%"). [interactive] lets git ask
  /// for a password in a terminal; the app passes false so nothing hangs.
  Future<CloneOutcome> clone({
    required String url,
    required String destination,
    required Profile profile,
    required Future<bool> Function(String profileId) hasToken,
    void Function(String line)? onProgress,
    bool interactive = false,
    bool track = true,
  }) async {
    final dest = resolveRepoPath(destination);
    final target = Directory(dest);
    if (target.existsSync() && target.listSync().isNotEmpty) {
      return CloneOutcome(
        ok: false,
        path: dest,
        message: 'There is already a folder at $dest. Pick another place or name.',
      );
    }

    // Make sure the profile's include file is current (sign-in, SSH key).
    await syncGitConfig(paths: paths, hasToken: hasToken);
    final include = paths.toGitConfigPath(
      GitConfigService(paths: paths).profileConfigPath(profile.id),
    );

    final process = await git.start(
      ['-c', 'include.path=$include', 'clone', '--progress', url.trim(), dest],
      environment: {if (!interactive) 'GIT_TERMINAL_PROMPT': '0'},
    );
    if (!interactive) await process.stdin.close();
    final errors = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .expand((l) => l.split('\r'))
        .forEach((line) {
      if (line.trim().isEmpty) return;
      errors.writeln(line);
      onProgress?.call(line.trim());
    });
    final stdoutDone = process.stdout.drain<void>();
    final code = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);

    if (code != 0) {
      return CloneOutcome(
        ok: false,
        path: dest,
        message: explainCloneError(
          errors.toString(),
          profile: profile,
          url: url,
          signedIn: await hasToken(profile.id),
        ),
      );
    }

    final top = resolveRepoPath(await git.topLevel(dest) ?? dest);
    final ruleRepo = RepoRuleRepository(paths: paths);
    final rules = await ruleRepo.getAll();
    var addedRule = false;
    if (RepoRule.bestMatchFor(top, rules)?.profileId != profile.id) {
      await ruleRepo.upsert(RepoRule(id: const Uuid().v4(), pathPattern: top, profileId: profile.id));
      await syncGitConfig(paths: paths, hasToken: hasToken);
      addedRule = true;
    }

    var guardAdded = false;
    String? guardProblem;
    if (track) {
      final guard = await HookService(paths: paths, git: git).install(top);
      guardAdded = guard.ok;
      if (!guard.ok) guardProblem = guard.message;
      await TrackedRepoRepository(paths: paths).upsert(TrackedRepo(
        path: top,
        lastScanned: DateTime.now(),
        hookInstalled: guard.ok,
      ));
    }

    return CloneOutcome(
      ok: true,
      path: top,
      addedRule: addedRule,
      guardAdded: guardAdded,
      guardProblem: guardProblem,
      message: 'Cloned to $top. Commits and pushes there use '
          '${profile.label} <${profile.gitEmail}>.',
    );
  }

  /// Turns git's clone error into what to do about it.
  static String explainCloneError(
    String stderr, {
    required Profile profile,
    required String url,
    required bool signedIn,
  }) {
    final e = stderr.toLowerCase();
    final who = profile.githubLogin == null ? profile.label : '${profile.label} (@${profile.githubLogin})';
    if (e.contains('permission denied (publickey)') || e.contains('host key verification failed')) {
      return "GitHub didn't accept $who's SSH key. Press \"Set up SSH\" in the "
          'profile, or clone with the HTTPS address instead.';
    }
    if (e.contains('repository not found') || e.contains('not found') && e.contains('remote')) {
      return signedIn
          ? "GitHub says this project doesn't exist, or $who's account can't "
              'see it. Check the address, and that the right profile is picked.'
          : "GitHub says this project doesn't exist, or it is private and "
              '${profile.label} is not signed in. Sign ${profile.label} in with '
              'GitHub, then try again.';
    }
    if (e.contains('authentication failed') ||
        e.contains('could not read username') ||
        e.contains('terminal prompts disabled') ||
        e.contains('403') ||
        e.contains('401')) {
      return signedIn
          ? "GitHub refused $who's sign-in. Sign ${profile.label} in with "
              'GitHub again, then try again.'
          : '${profile.label} is not signed in to GitHub, so GitHub only shows it '
              'public projects. If this one is private, sign ${profile.label} in '
              'and try again; otherwise check the address.';
    }
    if (e.contains('could not resolve host') || e.contains('unable to access') && e.contains('resolve')) {
      return "Couldn't reach the server. Check the internet connection and the address.";
    }
    if (e.contains('already exists and is not an empty directory')) {
      return 'There is already a folder there. Pick another place or name.';
    }
    if (e.contains('does not appear to be a git repository') || e.contains('not a valid repository name')) {
      return "That address isn't a git project. Copy it from the green Code button on GitHub.";
    }
    final lines = stderr
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('Cloning into'))
        .toList();
    return "The clone didn't work: ${lines.isEmpty ? 'git gave no reason' : lines.last}";
  }
}
