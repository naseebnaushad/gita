part of 'gita_cli.dart';

/// Sign-ins started with `gita sign-in --no-wait` (used by AI tools through
/// `gita mcp`) that are still waiting for the person, or that failed, by
/// profile id. `gita profiles` reports them.
final _backgroundSignIns = <String, String>{};

/// Commands that change Gita's setup, so it can be set up without the app
/// (by a script or an AI agent): `setup`, `profile`, `rule` and
/// `doctor --fix`.
extension _ManageCommands on GitaCli {
  Future<void> _sync() => syncGitConfig(paths: paths, hasToken: tokenStore.hasToken);

  // ---------------------------------------------------------------- setup

  /// Scans like `gita scan`, then saves what it found, as the app's
  /// "Set these up" button does.
  Future<int> _setup(ArgResults command, {required bool json}) async {
    final folders = command.rest;
    final missing = [for (final f in folders) if (!Directory(p.absolute(cwd, f)).existsSync()) f];
    if (missing.isNotEmpty) {
      _fail('No such folder: ${missing.join(', ')}', json: json);
      return ExitCodes.usage;
    }
    final scan = await MachineScanner(paths: paths, git: gitService).scan(
      searchFolders: folders.isEmpty ? null : [for (final f in folders) resolveRepoPath(p.absolute(cwd, f))],
      existingProfiles: await ProfileRepository(paths: paths).getAll(),
    );
    var suggestions = scan.suggestions;
    final only = {for (final e in command['only'] as List<String>) e.trim().toLowerCase()};
    if (only.isNotEmpty) {
      final found = {for (final s in suggestions) s.email.toLowerCase()};
      final unknown = only.difference(found);
      if (unknown.isNotEmpty) {
        _fail(
          'The scan found no projects using ${unknown.join(', ')}. '
          'It found: ${found.isEmpty ? 'none' : found.join(', ')}. '
          'Add that account by hand with: gita profile add --name <name> --email <email>',
          json: json,
        );
        return ExitCodes.usage;
      }
      suggestions = [for (final s in suggestions) if (only.contains(s.email.toLowerCase())) s];
    }
    if (suggestions.isEmpty) {
      _fail(
        'No accounts were found in ${scan.searchedFolders.isEmpty ? 'the usual project folders' : scan.searchedFolders.join(', ')}. '
        'Say where your projects are (gita setup <folder>), or add each '
        'account with: gita profile add --name <name> --email <email>',
        json: json,
      );
      return ExitCodes.problem;
    }

    final result = await SetupService(paths: paths, hasToken: tokenStore.hasToken, git: gitService).apply(
      [for (final s in suggestions) SetupChoice.from(s)],
      trackProjects: !(command['no-track'] as bool),
    );
    final needSignIn = [
      for (final pr in result.profiles)
        if (!await tokenStore.hasToken(pr.id)) pr,
    ];
    if (json) {
      out.writeln(_encode({
        'ok': true,
        ...result.toJson(),
        'needSignIn': [for (final pr in needSignIn) pr.id],
      }));
      return ExitCodes.ok;
    }
    out.writeln('Set up ${result.profiles.length} profile(s):');
    for (final pr in result.profiles) {
      out.writeln('  ${pr.label}: ${pr.gitName} <${pr.gitEmail}>  (id: ${pr.id})');
    }
    out.writeln('Added ${result.rules} folder rule(s) and ${result.sshKeys} SSH key(s), '
        'and the safety check to ${result.projects - result.projectProblems.length} project(s).');
    for (final problem in result.projectProblems) {
      out.writeln('  Safety check not added: $problem');
    }
    if (needSignIn.isNotEmpty) {
      out
        ..writeln()
        ..writeln('Next, sign each profile in to GitHub so HTTPS pushes use the right account:');
      for (final pr in needSignIn) {
        out.writeln('  gita sign-in --profile ${pr.id}    (${pr.label})');
      }
    }
    return ExitCodes.ok;
  }

  // -------------------------------------------------------------- profile

  Future<int> _profile(ArgResults command, {required bool json}) async {
    final rest = command.rest;
    final action = rest.isEmpty ? null : rest.first;
    if (action == 'add' && rest.length == 1) return _profileAdd(command, json: json);
    if (action == 'edit' && rest.length == 2) return _profileEdit(command, rest[1], json: json);
    _fail(
      'Usage: gita profile add --name <name> --email <email> [--label <label>] '
      '[--github-login <account>] [--folder <folder>]...\n'
      '   or: gita profile edit <name or id> [--name ...] [--email ...] [--label ...] [--github-login ...]',
      json: json,
    );
    return ExitCodes.usage;
  }

  static String? _opt(ArgResults command, String name) {
    final v = command[name] as String?;
    return v == null || v.trim().isEmpty ? null : v.trim();
  }

  static bool _looksLikeEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(s);

  Future<int> _profileAdd(ArgResults command, {required bool json}) async {
    final name = _opt(command, 'name');
    final email = _opt(command, 'email');
    if (name == null || email == null) {
      _fail('Give the name and email to commit with: gita profile add --name "Jane Doe" --email jane@acme.com', json: json);
      return ExitCodes.usage;
    }
    if (!_looksLikeEmail(email)) {
      _fail('"$email" is not an email address.', json: json);
      return ExitCodes.usage;
    }
    final repo = ProfileRepository(paths: paths);
    final profiles = await repo.getAll();
    final same = profiles.where((x) => x.gitEmail.toLowerCase() == email.toLowerCase()).firstOrNull;
    if (same != null) {
      _fail(
        'There is already a profile for $email: "${same.label}" (id: ${same.id}). '
        'Change it with: gita profile edit ${same.id} ...',
        json: json,
      );
      return ExitCodes.usage;
    }
    final label = _opt(command, 'label') ?? suggestLabel(email);
    if (profiles.any((x) => x.label.toLowerCase() == label.toLowerCase())) {
      _fail('There is already a profile called "$label". Pick another with --label.', json: json);
      return ExitCodes.usage;
    }
    final profile = Profile(
      id: const Uuid().v4(),
      label: label,
      gitName: name,
      gitEmail: email,
      githubLogin: _opt(command, 'github-login'),
      colorArgb: profileColorPalette[profiles.length % profileColorPalette.length],
      createdAt: DateTime.now(),
    );
    await repo.upsert(profile);

    final folders = [for (final f in command['folder'] as List<String>) _folderPath(f)];
    final ruleRepo = RepoRuleRepository(paths: paths);
    final rules = await ruleRepo.getAll();
    final added = <String>[];
    for (final folder in folders) {
      final existing = _folderRule(rules, folder);
      await ruleRepo.upsert(RepoRule(id: existing?.id ?? const Uuid().v4(), pathPattern: folder, profileId: profile.id));
      added.add(folder);
    }
    await _sync();

    if (json) {
      out.writeln(_encode({'ok': true, 'profile': _profileJson(profile), 'folders': added}));
    } else {
      out.writeln('Added "${profile.label}": commits as ${profile.gitName} <${profile.gitEmail}>  (id: ${profile.id})');
      for (final f in added) {
        out.writeln('Projects in $f now use it.');
      }
      if (added.isEmpty) {
        out.writeln('Say which folders use it with: gita rule add --profile ${profile.id} --folder <folder>');
      }
      out.writeln('Sign it in to GitHub with: gita sign-in --profile ${profile.id}');
    }
    return ExitCodes.ok;
  }

  Future<int> _profileEdit(ArgResults command, String wanted, {required bool json}) async {
    final repo = ProfileRepository(paths: paths);
    final profiles = await repo.getAll();
    final profile = GitaCli._findProfile(profiles, wanted);
    if (profile == null) {
      _failNoProfile(profiles, wanted, json: json);
      return ExitCodes.usage;
    }
    final email = _opt(command, 'email');
    if (email != null && !_looksLikeEmail(email)) {
      _fail('"$email" is not an email address.', json: json);
      return ExitCodes.usage;
    }
    if (email != null &&
        profiles.any((x) => x.id != profile.id && x.gitEmail.toLowerCase() == email.toLowerCase())) {
      _fail('Another profile already commits as $email.', json: json);
      return ExitCodes.usage;
    }
    final label = _opt(command, 'label');
    if (label != null &&
        profiles.any((x) => x.id != profile.id && x.label.toLowerCase() == label.toLowerCase())) {
      _fail('There is already a profile called "$label".', json: json);
      return ExitCodes.usage;
    }
    final updated = profile.copyWith(
      gitName: _opt(command, 'name'),
      gitEmail: email,
      label: label,
      githubLogin: _opt(command, 'github-login'),
    );
    if (identical(updated, profile) ||
        (updated.gitName == profile.gitName &&
            updated.gitEmail == profile.gitEmail &&
            updated.label == profile.label &&
            updated.githubLogin == profile.githubLogin)) {
      _fail('Nothing to change. Give --name, --email, --label or --github-login.', json: json);
      return ExitCodes.usage;
    }
    await repo.upsert(updated);
    await _sync();
    if (json) {
      out.writeln(_encode({'ok': true, 'profile': _profileJson(updated)}));
    } else {
      out.writeln('Saved "${updated.label}": commits as ${updated.gitName} <${updated.gitEmail}>'
          '${updated.githubLogin == null ? '' : ', GitHub account @${updated.githubLogin}'}.');
    }
    return ExitCodes.ok;
  }

  Map<String, Object?> _profileJson(Profile x) => {
        'id': x.id,
        'label': x.label,
        'name': x.gitName,
        'email': x.gitEmail,
        'githubLogin': x.githubLogin,
      };

  void _failNoProfile(List<Profile> profiles, String wanted, {required bool json}) {
    final names = profiles.map((x) => '"${x.label}" (${x.id})').join(', ');
    _fail(
      'There is no profile called "$wanted".'
      '${names.isEmpty ? ' Add one first: gita setup, or gita profile add.' : ' Profiles: $names'}',
      json: json,
    );
  }

  // ----------------------------------------------------------------- rule

  String _folderPath(String folder) => resolveRepoPath(p.normalize(p.absolute(cwd, folder)));

  static String _normFolder(String path) {
    var s = path.replaceAll('\\', '/').toLowerCase();
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static RepoRule? _folderRule(List<RepoRule> rules, String folder) => rules
      .where((r) => !r.isAccountRule && r.pathPattern.isNotEmpty && _normFolder(r.pathPattern) == _normFolder(folder))
      .firstOrNull;

  Future<int> _rule(ArgResults command, {required bool json}) async {
    final rest = command.rest;
    final action = rest.isEmpty ? null : rest.first;
    if (action == 'list' && rest.length == 1) return _ruleList(json: json);
    if (action == 'add' && rest.length == 1) return _ruleAdd(command, json: json);
    if (action == 'remove' && rest.length == 2) return _ruleRemove(rest[1], json: json);
    _fail(
      'Usage: gita rule list\n'
      '   or: gita rule add --profile <name or id> --folder <folder>\n'
      '   or: gita rule add --profile <name or id> --owner <GitHub account or organization> [--host <host>]\n'
      '   or: gita rule remove <rule id, folder, or host/owner>',
      json: json,
    );
    return ExitCodes.usage;
  }

  Map<String, Object?> _ruleJson(RepoRule r, Map<String, Profile> profiles) => {
        'id': r.id,
        'kind': r.isAccountRule ? 'account' : (r.isProjectRule ? 'project' : 'folder'),
        'covers': r.describe,
        'profileId': r.profileId,
        'profile': profiles[r.profileId]?.label,
      };

  Future<int> _ruleList({required bool json}) async {
    final rules = await RepoRuleRepository(paths: paths).getAll();
    final profiles = {for (final x in await ProfileRepository(paths: paths).getAll()) x.id: x};
    if (json) {
      out.writeln(_encode({
        'ok': true,
        'rules': [for (final r in RepoRule.inEmitOrder(rules)) _ruleJson(r, profiles)],
      }));
      return ExitCodes.ok;
    }
    if (rules.isEmpty) {
      out.writeln('No rules yet. Add one with: gita rule add --profile <name> --folder <folder>');
      return ExitCodes.ok;
    }
    for (final r in RepoRule.inEmitOrder(rules)) {
      final who = profiles[r.profileId];
      final what = r.isAccountRule ? 'Projects from ${r.describe}' : r.describe;
      out.writeln('$what  ->  ${who == null ? 'deleted profile' : '${who.label} <${who.gitEmail}>'}  (id: ${r.id})');
    }
    return ExitCodes.ok;
  }

  Future<int> _ruleAdd(ArgResults command, {required bool json}) async {
    final wanted = _opt(command, 'profile');
    final folder = _opt(command, 'folder');
    final owner = _opt(command, 'owner');
    if (wanted == null || (folder == null) == (owner == null)) {
      _fail(
        'Give --profile and either --folder (projects in that folder) or --owner '
        '(projects from that GitHub account or organization, wherever they are).',
        json: json,
      );
      return ExitCodes.usage;
    }
    final profiles = await ProfileRepository(paths: paths).getAll();
    final profile = GitaCli._findProfile(profiles, wanted);
    if (profile == null) {
      _failNoProfile(profiles, wanted, json: json);
      return ExitCodes.usage;
    }
    final ruleRepo = RepoRuleRepository(paths: paths);
    final rules = await ruleRepo.getAll();
    final RepoRule rule;
    String? replaced;
    if (folder != null) {
      final path = _folderPath(folder);
      final existing = _folderRule(rules, path);
      if (existing != null && existing.profileId != profile.id) replaced = existing.profileId;
      rule = RepoRule(id: existing?.id ?? const Uuid().v4(), pathPattern: path, profileId: profile.id);
    } else {
      final host = (_opt(command, 'host') ?? RepoRule.defaultHost).toLowerCase();
      final name = owner!.replaceAll(RegExp(r'^@|/+$'), '');
      if (name.isEmpty || name.contains('/') || name.contains(' ')) {
        _fail('"$owner" is not a GitHub account or organization name (like "acme").', json: json);
        return ExitCodes.usage;
      }
      final existing = rules
          .where((r) => r.isAccountRule && r.host == host && r.githubOwner!.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (existing != null && existing.profileId != profile.id) replaced = existing.profileId;
      rule = RepoRule.account(
        id: existing?.id ?? const Uuid().v4(),
        owner: existing?.githubOwner ?? name,
        profileId: profile.id,
        host: host,
      );
    }
    await ruleRepo.upsert(rule);
    await _sync();
    final before = profiles.where((x) => x.id == replaced).firstOrNull;
    final message = '${rule.isAccountRule ? 'Projects from ${rule.describe}' : 'Projects in ${rule.describe}'} '
        'now use "${profile.label}" (${profile.gitEmail})'
        '${before == null ? '' : ' instead of "${before.label}"'}.';
    if (json) {
      out.writeln(_encode({
        'ok': true,
        'rule': _ruleJson(rule, {for (final x in profiles) x.id: x}),
        'replacedProfile': ?before?.id,
        'message': message,
      }));
    } else {
      out.writeln(message);
    }
    return ExitCodes.ok;
  }

  Future<int> _ruleRemove(String wanted, {required bool json}) async {
    final ruleRepo = RepoRuleRepository(paths: paths);
    final rules = await ruleRepo.getAll();
    final w = wanted.trim();
    final rule = rules.where((r) => r.id == w).firstOrNull ??
        rules.where((r) => r.isAccountRule && r.describe.toLowerCase() == w.toLowerCase()).firstOrNull ??
        rules.where((r) => r.isAccountRule && r.host == RepoRule.defaultHost && r.githubOwner!.toLowerCase() == w.toLowerCase()).firstOrNull ??
        _folderRule(rules, _folderPath(w));
    if (rule == null) {
      _fail('There is no rule for "$wanted". See the rules with: gita rule list', json: json);
      return ExitCodes.usage;
    }
    await ruleRepo.delete(rule.id);
    await _sync();
    final message = 'Removed the rule for ${rule.isAccountRule ? 'projects from ${rule.describe}' : rule.describe}.';
    if (json) {
      out.writeln(_encode({'ok': true, 'removed': rule.id, 'message': message}));
    } else {
      out.writeln(message);
    }
    return ExitCodes.ok;
  }

  // ----------------------------------------------------------- doctor fix

  /// Applies the Doctor fixes that need no person: removing rules and SSH
  /// key links that point at something deleted, and making a company
  /// organization's projects use the company profile. Returns what was
  /// done. Turning commit signing off, signing in and making SSH keys are
  /// left for the person.
  Future<List<String>> _applyDoctorFixes(List<DoctorIssue> issues) async {
    final done = <String>[];
    final profileRepo = ProfileRepository(paths: paths);
    final ruleRepo = RepoRuleRepository(paths: paths);
    for (final issue in issues) {
      switch (issue.category) {
        case DoctorCategory.orphanedRuleProfile when issue.ruleId != null:
          final rule = (await ruleRepo.getAll()).where((r) => r.id == issue.ruleId).firstOrNull;
          if (rule == null) continue;
          await ruleRepo.delete(rule.id);
          done.add('Removed the rule for ${rule.describe}: its profile was deleted.');
        case DoctorCategory.orphanedSshKeyReference when issue.profileId != null:
          final profile = (await profileRepo.getAll()).where((x) => x.id == issue.profileId).firstOrNull;
          if (profile == null || profile.sshKeyId == null) continue;
          await profileRepo.upsert(profile.copyWith(clearSshKeyId: true));
          done.add('"${profile.label}" no longer points at an SSH key that was deleted.');
        case DoctorCategory.companyEmailMismatch || DoctorCategory.companyOwnerUnmapped
            when issue.profileId != null && issue.githubOwner != null:
          final profile = (await profileRepo.getAll()).where((x) => x.id == issue.profileId).firstOrNull;
          if (profile == null) continue;
          final host = issue.host ?? RepoRule.defaultHost;
          final owner = issue.githubOwner!;
          final existing = (await ruleRepo.getAll())
              .where((r) => r.isAccountRule && r.host == host && r.githubOwner!.toLowerCase() == owner.toLowerCase())
              .firstOrNull;
          await ruleRepo.upsert(RepoRule.account(
            id: existing?.id ?? const Uuid().v4(),
            owner: existing?.githubOwner ?? owner,
            profileId: profile.id,
            host: host,
          ));
          done.add('Projects from $host/$owner now use "${profile.label}" (${profile.gitEmail}).');
        default:
          break;
      }
    }
    if (done.isNotEmpty) await _sync();
    return done;
  }
}
