import 'dart:io';

import '../models/doctor_issue.dart';
import '../models/mismatch_report.dart' show Severity;
import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/ssh_key.dart';
import 'company_setup.dart';
import 'gpg_service.dart';
import 'keychain_store.dart';
import 'platform_paths.dart';
import 'sign_in_checker.dart';
import 'token_store.dart';

/// Scans profiles/rules/SSH keys for config drift that won't show up until
/// a commit or push actually fails — e.g. a profile with signing enabled
/// but no matching GPG secret key on this machine, or an SSH key whose file
/// was moved or deleted. Complements [MismatchDetector], which only checks
/// one repo's live state against its expected profile.
class IdentityDoctorService {
  const IdentityDoctorService({
    this.gpgService = const GpgService(),
    this.paths = const PlatformPaths(),
    this.tokenStore,
    this.signInChecker,
  });

  final GpgService gpgService;
  final PlatformPaths paths;

  /// Where profile tokens live. Null skips the HTTPS sign-in checks.
  final TokenStore? tokenStore;

  /// Asks GitHub whether each saved sign-in still works. Null skips that
  /// check (it needs the internet).
  final SignInChecker? signInChecker;

  Future<List<DoctorIssue>> run({
    required List<Profile> profiles,
    required List<RepoRule> rules,
    required List<SshKey> sshKeys,
  }) async {
    final issues = <DoctorIssue>[];
    final sshKeysById = {for (final k in sshKeys) k.id: k};
    final profilesById = {for (final p in profiles) p.id: p};

    final gpgInstalled = await gpgService.isInstalled();

    for (final profile in profiles) {
      final wantsSigning = profile.signCommitsByDefault || profile.gpgKeyId != null;
      if (wantsSigning) {
        if (!gpgInstalled) {
          issues.add(DoctorIssue(
            category: DoctorCategory.gpgNotInstalled,
            severity: Severity.blocking,
            message: '"${profile.label}" has commit signing enabled but gpg '
                'is not installed or not on PATH. Commits in this profile '
                'will fail.',
            profileId: profile.id,
          ));
        } else {
          final identity = profile.gpgKeyId ?? profile.gitEmail;
          final hasKey = await gpgService.hasSecretKeyFor(identity);
          if (!hasKey) {
            issues.add(DoctorIssue(
              category: DoctorCategory.missingSigningKey,
              severity: Severity.blocking,
              message: '"${profile.label}" has commit signing enabled but '
                  'no GPG secret key exists for $identity. Commits will '
                  'fail until a key is generated or imported.',
              profileId: profile.id,
            ));
          }
        }
      }

      final sshKeyId = profile.sshKeyId;
      if (sshKeyId != null) {
        final key = sshKeysById[sshKeyId];
        if (key == null) {
          issues.add(DoctorIssue(
            category: DoctorCategory.orphanedSshKeyReference,
            severity: Severity.warning,
            message: '"${profile.label}" references an SSH key that no '
                'longer exists.',
            profileId: profile.id,
          ));
        } else if (!File(key.privateKeyPath).existsSync()) {
          issues.add(DoctorIssue(
            category: DoctorCategory.missingSshKeyFile,
            severity: Severity.blocking,
            message: '"${profile.label}" expects SSH key "${key.label}" at '
                '${key.privateKeyPath}, but that file is missing.',
            profileId: profile.id,
            sshKeyId: key.id,
          ));
        }
      }
    }

    issues.addAll(await _pushSignInIssues(profiles));
    issues.addAll(await _companyIssues(profiles, rules, profilesById));

    for (final rule in rules) {
      if (!profilesById.containsKey(rule.profileId)) {
        issues.add(
          DoctorIssue(
            category: DoctorCategory.orphanedRuleProfile,
            severity: Severity.warning,
            message:
                'Rule for "${rule.describe}" points at a profile '
                'that no longer exists.',
            ruleId: rule.id,
          ),
        );
      }
    }

    return issues;
  }

  /// Checks each imported company setup: its organizations should use a
  /// profile that commits with a company email.
  Future<List<DoctorIssue>> _companyIssues(
    List<Profile> profiles,
    List<RepoRule> rules,
    Map<String, Profile> profilesById,
  ) async {
    final issues = <DoctorIssue>[];
    for (final setup in await CompanyService(paths: paths).load()) {
      final companyProfiles = setup.companyProfiles(profiles);
      final suggested = CompanyService.pickProfile(setup, profiles);
      final domains = setup.emailDomains.map((d) => '@$d').join(' or ');
      if (companyProfiles.isEmpty && setup.emailDomains.isNotEmpty) {
        issues.add(
          DoctorIssue(
            category: DoctorCategory.companyNoProfile,
            severity: Severity.warning,
            message:
                'No profile commits with a ${setup.name} email ($domains). '
                'Add one under Profiles (or press "Scan this computer"), so '
                '${setup.name} projects are committed with your work email.',
          ),
        );
      }
      for (final owner in setup.owners) {
        final where = '${setup.host}/$owner';
        final rule = setup.ruleFor(owner, rules);
        if (rule == null) {
          issues.add(
            DoctorIssue(
              category: DoctorCategory.companyOwnerUnmapped,
              severity: Severity.warning,
              message:
                  'Projects from $where (${setup.name}) have no profile '
                  'set, so they use whatever their folder says.'
                  '${suggested == null ? '' : ' They should use "${suggested.label}".'}',
              profileId: suggested?.id,
              githubOwner: owner,
              host: setup.host,
            ),
          );
          continue;
        }
        final profile = profilesById[rule.profileId];
        if (profile == null || setup.emailDomains.isEmpty) continue;
        if (!setup.isCompanyEmail(profile.gitEmail)) {
          issues.add(
            DoctorIssue(
              category: DoctorCategory.companyEmailMismatch,
              severity: Severity.blocking,
              message:
                  'Projects from $where (${setup.name}) use "${profile.label}", '
                  'which commits as ${profile.gitEmail}, not a $domains email.'
                  '${suggested == null ? '' : ' They should use "${suggested.label}".'}',
              profileId: suggested?.id,
              ruleId: rule.id,
              githubOwner: owner,
              host: setup.host,
            ),
          );
        }
      }
    }
    return issues;
  }

  Future<List<DoctorIssue>> _pushSignInIssues(List<Profile> profiles) async {
    final store = tokenStore;
    if (store == null || profiles.isEmpty) return const [];
    final issues = <DoctorIssue>[];
    final cliInstalled = File(paths.cliPath).existsSync();

    for (final profile in profiles) {
      final bool hasToken;
      try {
        hasToken = await store.hasToken(profile.id);
      } on KeychainException catch (e) {
        return [
          DoctorIssue(
            category: DoctorCategory.keychainUnavailable,
            severity: Severity.warning,
            message: "Gita couldn't open this computer's password store, "
                "so it can't check GitHub sign-ins. ${e.message}",
          ),
        ];
      }

      if (hasToken) {
        final issue = await _signInHealthIssue(store, profile);
        if (issue != null) issues.add(issue);
      }

      if (hasToken && !cliInstalled) {
        issues.add(DoctorIssue(
          category: DoctorCategory.credentialHelperNotInstalled,
          severity: Severity.warning,
          message: '"${profile.label}" has a GitHub sign-in saved, but the '
              "gita command isn't installed at ${paths.cliPath}, so pushes "
              "can't use it yet. Pushes will use whichever GitHub account "
              'this computer remembers, which may be the wrong one. Gita '
              'installs the command each time it starts: close and reopen '
              'Gita. If this message stays, reinstall Gita.',
          profileId: profile.id,
        ));
      } else if (!hasToken && profile.sshKeyId == null) {
        issues.add(DoctorIssue(
          category: DoctorCategory.missingPushToken,
          severity: Severity.warning,
          message: '"${profile.label}" has no GitHub sign-in saved. Pushes '
              'from its projects will use whichever GitHub account this '
              'computer remembers, which may be the wrong one. Sign it in: '
              'open Profiles, edit "${profile.label}" and press "Sign in '
              'with GitHub" (or paste an access token there).',
          profileId: profile.id,
        ));
      }
    }
    return issues;
  }

  /// Asks GitHub whether [profile]'s saved sign-in still works. Says
  /// nothing when GitHub can't be reached: a false alarm would send people
  /// to sign in again for nothing, and each new sign-in can cancel an old
  /// one (GitHub keeps 10 per account).
  Future<DoctorIssue?> _signInHealthIssue(TokenStore store, Profile profile) async {
    final checker = signInChecker;
    if (checker == null) return null;
    final String? token;
    try {
      token = await store.readToken(profile.id);
    } on KeychainException {
      return null;
    }
    if (token == null || token.isEmpty) return null;
    final result = await checker.check(token);
    switch (result.health) {
      case SignInHealth.rejected:
        return DoctorIssue(
          category: DoctorCategory.signInRejected,
          severity: Severity.blocking,
          message: "\"${profile.label}\"'s GitHub sign-in has stopped working: "
              'GitHub no longer accepts it. It may have been cancelled on '
              'GitHub (this happens after signing in to Gita many times, since '
              'GitHub keeps only the 10 newest). Pushes from its projects will '
              'fail or ask for a password until it is signed in again. Open '
              'Profiles, edit "${profile.label}" and press "Sign in with GitHub".',
          profileId: profile.id,
        );
      case SignInHealth.working:
        final expected = profile.githubLogin;
        final actual = result.login!;
        if (expected == null || expected.toLowerCase() == actual.toLowerCase()) {
          return null;
        }
        return DoctorIssue(
          category: DoctorCategory.signInWrongAccount,
          severity: Severity.warning,
          message: '"${profile.label}" should push as @$expected, but its saved '
              'sign-in belongs to @$actual. Pushes from its projects will use '
              '@$actual. Sign it in again as @$expected: open Profiles, edit '
              '"${profile.label}" and press "Sign in with GitHub".',
          profileId: profile.id,
        );
      case SignInHealth.unknown:
        return null;
    }
  }
}
