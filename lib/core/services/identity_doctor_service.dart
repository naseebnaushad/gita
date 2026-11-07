import 'dart:io';

import '../models/doctor_issue.dart';
import '../models/mismatch_report.dart' show Severity;
import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/ssh_key.dart';
import 'gpg_service.dart';
import 'keychain_store.dart';
import 'platform_paths.dart';
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
  });

  final GpgService gpgService;
  final PlatformPaths paths;

  /// Where profile tokens live. Null skips the HTTPS sign-in checks.
  final TokenStore? tokenStore;

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

    for (final rule in rules) {
      if (!profilesById.containsKey(rule.profileId)) {
        issues.add(DoctorIssue(
          category: DoctorCategory.orphanedRuleProfile,
          severity: Severity.warning,
          message: 'Rule for "${rule.pathPattern}" points at a profile '
              'that no longer exists.',
          ruleId: rule.id,
        ));
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
              'computer remembers, which may be the wrong one. Open '
              'Profiles, edit "${profile.label}" and paste an access token.',
          profileId: profile.id,
        ));
      }
    }
    return issues;
  }
}
