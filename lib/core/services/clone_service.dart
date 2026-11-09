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

/// Kinds of clone failure the app can offer a fix for.
enum CloneProblem {
  /// The profile needs (another) GitHub sign-in.
  signIn,

  /// The profile is signed in, but git couldn't get the sign-in from
  /// Gita's helper (the `gita` command): reinstalling it is the fix.
  helper,

  /// GitHub didn't accept the profile's SSH key.
  sshKey,
}

/// A failed clone, explained.
class CloneError {
  const CloneError(this.message, {this.problem, this.gitDetail});

  final String message;
  final CloneProblem? problem;
  final String? gitDetail;
}

/// What happened when Gita cloned a project.
class CloneOutcome {
  const CloneOutcome({
    required this.ok,
    required this.path,
    required this.message,
    this.addedRule = false,
    this.guardAdded = false,
    this.guardProblem,
    this.problem,
    this.gitDetail,
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

  /// For a failed clone: what kind of problem it was, when one of the
  /// [CloneProblem]s fits (the app offers a fix for those).
  final CloneProblem? problem;

  /// For a failed clone: git's own last error line.
  final String? gitDetail;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'path': path,
        'message': message,
        'addedRule': addedRule,
        'safetyCheck': guardAdded,
        if (guardProblem != null) 'safetyCheckProblem': guardProblem,
        if (problem != null) 'problem': problem!.name,
        if (gitDetail != null) 'gitSaid': gitDetail,
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

  /// The profile for the project at [url]: an account rule for its
  /// GitHub organization first, else the profile whose GitHub account
  /// owns it.
  static Profile? suggestProfile(
    String url,
    List<Profile> profiles, {
    List<RepoRule> rules = const [],
  }) {
    for (final rule in RepoRule.inEmitOrder(
      rules.where((r) => r.isAccountRule).toList(),
    ).reversed) {
      if (rule.coversRemote(url)) {
        final match = profiles.where((p) => p.id == rule.profileId).firstOrNull;
        if (match != null) return match;
      }
    }
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
          if (r.profileId == profile.id &&
              !r.isAccountRule &&
              r.pathPattern.isNotEmpty)
            r.pathPattern.replaceAll('\\', '/'),
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
      final explained = classifyCloneError(
        errors.toString(),
        profile: profile,
        url: url,
        signedIn: await hasToken(profile.id),
        helperInstalled: File(paths.cliPath).existsSync(),
      );
      return CloneOutcome(
        ok: false,
        path: dest,
        message: explained.message,
        problem: explained.problem,
        gitDetail: explained.gitDetail,
      );
    }

    final top = resolveRepoPath(await git.topLevel(dest) ?? dest);
    final ruleRepo = RepoRuleRepository(paths: paths);
    final rules = await ruleRepo.getAll();
    var addedRule = false;
    final urls = {url.trim(), ...await git.remoteUrls(top)}.toList();
    if (RepoRule.bestMatchFor(top, rules, remoteUrls: urls)?.profileId !=
        profile.id) {
      await ruleRepo.upsert(
        RepoRule(
          id: const Uuid().v4(),
          pathPattern: top,
          profileId: profile.id,
        ),
      );
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
    bool helperInstalled = true,
  }) =>
      classifyCloneError(stderr,
              profile: profile, url: url, signedIn: signedIn, helperInstalled: helperInstalled)
          .message;

  /// What went wrong with a clone, what to tell the person, and what can
  /// fix it ([CloneError.problem]: the app offers a button for some).
  ///
  /// [helperInstalled] is whether Gita's `gita` command, which git runs to
  /// get a profile's GitHub sign-in, is where the git settings point.
  static CloneError classifyCloneError(
    String stderr, {
    required Profile profile,
    required String url,
    required bool signedIn,
    bool helperInstalled = true,
  }) {
    final e = stderr.toLowerCase();
    final detail = gitDetail(stderr);
    final who = profile.githubLogin == null ? profile.label : '${profile.label} (@${profile.githubLogin})';
    final label = profile.label;
    CloneError error(String message, [CloneProblem? problem]) =>
        CloneError(message, problem: problem, gitDetail: detail);

    if (e.contains('permission denied (publickey)') || e.contains('host key verification failed')) {
      return error(
          "GitHub didn't accept $who's SSH key. Press \"Set up SSH\" in the "
          'profile, or clone with the HTTPS address instead.',
          CloneProblem.sshKey);
    }

    // An organization with SAML single sign-on refuses sign-ins that
    // haven't been allowed for it, even valid ones.
    if (e.contains('saml') || e.contains('single sign-on') || e.contains(' sso')) {
      final org = ownerFromUrl(url);
      return error(
          '${org == null ? 'This organization' : 'The $org organization'} uses single sign-on, and '
          "GitHub won't let $who's sign-in see its projects until it is allowed for "
          '${org ?? 'it'}. Sign $label in with GitHub again and allow the organization '
          'when GitHub asks (or on github.com: Settings → Applications → Gita).',
          CloneProblem.signIn);
    }

    final askedForLogin = e.contains('could not read username') ||
        e.contains('could not read password') ||
        e.contains('terminal prompts disabled');
    final helperQuit = e.contains('told us to quit');
    final authFailed = e.contains('authentication failed') ||
        e.contains('invalid username or password') ||
        e.contains('invalid username or token') ||
        e.contains('bad credentials') ||
        RegExp(r'\b(401|403)\b').hasMatch(e);

    if (signedIn && (askedForLogin || helperQuit || authFailed || e.contains('gita:'))) {
      // Git runs `gita credential` to get the sign-in. When git still had
      // to ask for a login, the sign-in never reached GitHub: signing in
      // again won't help, the helper needs fixing.
      if (!helperInstalled) {
        return error(
            "$label is signed in, but Gita's sign-in helper (the gita command) isn't "
            'installed, so git couldn\'t use the sign-in. Let Gita install it, then try again.',
            CloneProblem.helper);
      }
      if (e.contains("gita: couldn't open")) {
        return error(
            "Gita couldn't read $label's GitHub sign-in from this computer's password "
            'store, so git had none to use. Unlock it (or sign in to your computer '
            'again), then try again.',
            CloneProblem.helper);
      }
      if (e.contains('gita: there is no github sign-in saved')) {
        return error(
            "Gita's sign-in helper found no saved GitHub sign-in for $label. Sign $label "
            'in with GitHub again, then try again.',
            CloneProblem.signIn);
      }
      if (askedForLogin || helperQuit) {
        return error(
            "$label is signed in, but git didn't get the sign-in from Gita's helper (the "
            'gita command). Let Gita reinstall it, then try again.',
            CloneProblem.helper);
      }
      return error(
          "GitHub didn't accept $who's saved sign-in: it may have been revoked or have "
          'expired. Sign $label in with GitHub again, then try again.',
          CloneProblem.signIn);
    }

    if (e.contains('repository not found') || e.contains('not found') && e.contains('remote')) {
      return signedIn
          ? error("GitHub says this project doesn't exist, or $who's account can't "
              'see it. Check the address, and that the right profile is picked.')
          : error(
              "GitHub says this project doesn't exist, or it is private and "
              '$label is not signed in. Sign $label in with GitHub, then try again.',
              CloneProblem.signIn);
    }
    if (askedForLogin || helperQuit || authFailed) {
      return error(
          '$label is not signed in to GitHub, so GitHub only shows it public projects. '
          'If this one is private, sign $label in and try again; otherwise check the address.',
          CloneProblem.signIn);
    }
    if (e.contains('could not resolve host') || e.contains('unable to access') && e.contains('resolve')) {
      return error("Couldn't reach the server. Check the internet connection and the address.");
    }
    if (e.contains('already exists and is not an empty directory')) {
      return error('There is already a folder there. Pick another place or name.');
    }
    if (e.contains('does not appear to be a git repository') || e.contains('not a valid repository name')) {
      return error("That address isn't a git project. Copy it from the green Code button on GitHub.");
    }
    return error("The clone didn't work: ${detail ?? 'git gave no reason'}");
  }

  /// Git's own last error line, for showing under the plain-language
  /// message. Passwords or tokens written into an address are hidden.
  static String? gitDetail(String stderr) {
    final lines = stderr
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('Cloning into'))
        .toList();
    if (lines.isEmpty) return null;
    final fatal = lines.lastWhere(
      (l) => l.startsWith('fatal:') || l.startsWith('error:'),
      orElse: () => lines.last,
    );
    return fatal.replaceAllMapped(RegExp(r'://[^/@\s]+@'), (_) => '://***@');
  }
}
