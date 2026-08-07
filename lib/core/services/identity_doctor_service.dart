import 'dart:io';

import '../models/doctor_issue.dart';
import '../models/mismatch_report.dart' show Severity;
import '../models/profile.dart';
import '../models/repo_rule.dart';
import '../models/ssh_key.dart';
import 'gpg_service.dart';

/// Scans profiles/rules/SSH keys for config drift that won't show up until
/// a commit or push actually fails — e.g. a profile with signing enabled
/// but no matching GPG secret key on this machine, or an SSH key whose file
/// was moved or deleted. Complements [MismatchDetector], which only checks
/// one repo's live state against its expected profile.
class IdentityDoctorService {
  const IdentityDoctorService({this.gpgService = const GpgService()});

  final GpgService gpgService;

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
}
