import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../storage/repositories.dart';
import 'git_config_sync.dart';
import 'platform_paths.dart';

/// A company's setup, shared as a small file by whoever looks after
/// developer machines:
///
/// ```json
/// {
///   "name": "Acme",
///   "emailDomains": ["acme.com"],
///   "github": { "host": "github.com", "owners": ["acme", "acme-labs"] }
/// }
/// ```
///
/// Importing it makes every project from those GitHub organizations use
/// the profile with a company email, and lets Doctor warn when that drifts.
class CompanySetup {
  const CompanySetup({
    required this.name,
    required this.emailDomains,
    required this.owners,
    this.host = RepoRule.defaultHost,
  });

  final String name;

  /// Lower-case, without `@`, e.g. `acme.com`.
  final List<String> emailDomains;

  /// GitHub organizations (or accounts) whose projects are company work.
  final List<String> owners;
  final String host;

  /// Reads a setup file's text. Throws [FormatException] with a plain
  /// message saying what's wrong.
  static CompanySetup parse(String text) {
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      throw const FormatException(
        "This isn't a company setup file: it should be JSON, like "
        '{"name": "Acme", "emailDomains": ["acme.com"], "github": {"owners": ["acme"]}}',
      );
    }
    if (data is! Map<String, dynamic>) {
      throw const FormatException(
        'The company setup file should be one JSON object.',
      );
    }
    return CompanySetup.fromJson(data);
  }

  factory CompanySetup.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException(
        'The company setup file needs a "name", e.g. "Acme".',
      );
    }
    final github = json['github'];
    final githubMap = github is Map<String, dynamic>
        ? github
        : const <String, dynamic>{};
    List<String> strings(Object? v) => v is List
        ? [
            for (final x in v)
              if (x is String && x.trim().isNotEmpty) x.trim(),
          ]
        : const [];
    final domains = [
      for (final d in strings(json['emailDomains']))
        d.toLowerCase().replaceFirst(RegExp('^@'), ''),
    ];
    final owners = strings(githubMap['owners']);
    if (owners.isEmpty) {
      throw const FormatException(
        'The company setup file needs the GitHub organizations under '
        '"github": {"owners": ["acme"]}.',
      );
    }
    final host = githubMap['host'];
    return CompanySetup(
      name: name.trim(),
      emailDomains: domains,
      owners: owners,
      host: host is String && host.trim().isNotEmpty
          ? host.trim().toLowerCase()
          : RepoRule.defaultHost,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'emailDomains': emailDomains,
    'github': {'host': host, 'owners': owners},
  };

  /// True when [email] is at one of the company's domains.
  bool isCompanyEmail(String email) {
    final at = email.lastIndexOf('@');
    if (at < 0) return false;
    final domain = email.substring(at + 1).trim().toLowerCase();
    return emailDomains.any((d) => domain == d || domain.endsWith('.$d'));
  }

  /// Profiles that commit with a company email.
  List<Profile> companyProfiles(List<Profile> profiles) => [
    for (final p in profiles)
      if (isCompanyEmail(p.gitEmail)) p,
  ];

  /// The account rule for [owner], if there is one.
  RepoRule? ruleFor(String owner, List<RepoRule> rules) => rules
      .where(
        (r) =>
            r.isAccountRule &&
            r.host == host &&
            r.githubOwner!.toLowerCase() == owner.toLowerCase(),
      )
      .firstOrNull;
}

/// What importing a company setup changed.
class CompanyImportResult {
  const CompanyImportResult({
    required this.profile,
    required this.added,
    required this.moved,
    required this.unchanged,
  });

  final Profile profile;

  /// Organizations that now have a rule.
  final List<String> added;

  /// Organizations whose rule pointed at another profile and now point
  /// at [profile].
  final List<String> moved;

  /// Organizations already set up for [profile].
  final List<String> unchanged;

  String message(CompanySetup setup) {
    final changed = [...added, ...moved];
    final where = setup.owners.map((o) => '${setup.host}/$o').join(', ');
    if (changed.isEmpty) {
      return 'Already set up: projects from $where use "${profile.label}".';
    }
    return 'Done. Projects from $where now use "${profile.label}" '
        '(${profile.gitEmail}), wherever they are on this computer.';
  }

  Map<String, Object?> toJson() => {
    'profile': profile.id,
    'added': added,
    'moved': moved,
    'unchanged': unchanged,
  };
}

/// Saves company setups and turns them into account rules. Shared by
/// the app and `gita company`.
class CompanyService {
  const CompanyService({required this.paths});

  final PlatformPaths paths;

  File get _file => File(paths.companyJsonPath);

  /// The company setups imported on this computer.
  Future<List<CompanySetup>> load() async {
    if (!await _file.exists()) return const [];
    try {
      final data = jsonDecode(await _file.readAsString());
      final list = data is Map<String, dynamic> ? data['companies'] : null;
      if (list is! List) return const [];
      return [
        for (final c in list)
          if (c is Map<String, dynamic>) CompanySetup.fromJson(c),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> _save(List<CompanySetup> setups) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'companies': [for (final s in setups) s.toJson()],
      }),
    );
  }

  /// The profile to use for [setup] when the person didn't pick one: the
  /// only profile with a company email. Null when there's none or several.
  static Profile? pickProfile(CompanySetup setup, List<Profile> profiles) {
    final matches = setup.companyProfiles(profiles);
    return matches.length == 1 ? matches.single : null;
  }

  /// Makes every project from [setup]'s organizations use [profile],
  /// remembers the setup (replacing one with the same name), and rewrites
  /// git's settings.
  Future<CompanyImportResult> import(
    CompanySetup setup,
    Profile profile, {
    required Future<bool> Function(String profileId) hasToken,
  }) async {
    final ruleRepo = RepoRuleRepository(paths: paths);
    final rules = await ruleRepo.getAll();
    final added = <String>[];
    final moved = <String>[];
    final unchanged = <String>[];
    for (final owner in setup.owners) {
      final existing = setup.ruleFor(owner, rules);
      if (existing == null) {
        await ruleRepo.upsert(
          RepoRule.account(
            id: const Uuid().v4(),
            owner: owner,
            profileId: profile.id,
            host: setup.host,
          ),
        );
        added.add(owner);
      } else if (existing.profileId != profile.id) {
        await ruleRepo.upsert(
          RepoRule.account(
            id: existing.id,
            owner: existing.githubOwner!,
            profileId: profile.id,
            host: setup.host,
          ),
        );
        moved.add(owner);
      } else {
        unchanged.add(owner);
      }
    }

    final setups = [
      for (final s in await load())
        if (s.name.toLowerCase() != setup.name.toLowerCase()) s,
      setup,
    ];
    await _save(setups);
    if (added.isNotEmpty || moved.isNotEmpty) {
      await syncGitConfig(paths: paths, hasToken: hasToken);
    }
    return CompanyImportResult(
      profile: profile,
      added: added,
      moved: moved,
      unchanged: unchanged,
    );
  }
}
