import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/doctor_issue.dart';
import '../../core/models/mismatch_report.dart' show Severity;
import '../../core/models/profile.dart';
import '../../core/providers.dart';
import '../../core/services/doctor_fixes.dart';
import '../../widgets/empty_state.dart';
import '../profiles/github_sign_in_dialog.dart';
import '../profiles/profiles_screen.dart' show showProfileEditor;
import '../../widgets/screen_header.dart';
import '../../widgets/status_chip.dart';

class DoctorScreen extends ConsumerWidget {
  const DoctorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issuesAsync = ref.watch(doctorIssuesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenHeader(
          title: 'Doctor',
          subtitle: 'Checks your setup for problems before they cause a '
              'failed commit or push.',
          actions: [
            OutlinedButton.icon(
              onPressed: () => ref.invalidate(doctorIssuesProvider),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Re-run checks'),
            ),
          ],
        ),
        Expanded(
          child: issuesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Failed to run checks: $e')),
            data: (issues) {
              if (issues.isEmpty) {
                return const EmptyState(
                  icon: Icons.verified_outlined,
                  title: 'All clear',
                  message: 'No issues found. Profiles, rules, and keys are consistent.',
                );
              }
              final blocking = issues.where((i) => i.severity == Severity.blocking).toList();
              final warnings = issues.where((i) => i.severity == Severity.warning).toList();
              return ListView(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                children: [
                  if (blocking.isNotEmpty) ...[
                    _SectionHeader(
                      icon: Icons.cancel_rounded,
                      color: GitaColors.red,
                      label: '${blocking.length} would block a commit',
                    ),
                    const SizedBox(height: 10),
                    for (final issue in blocking) ...[
                      _IssueTile(issue: issue),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (warnings.isNotEmpty) ...[
                    _SectionHeader(
                      icon: Icons.warning_rounded,
                      color: GitaColors.amber,
                      label: '${warnings.length} configuration warning(s)',
                    ),
                    const SizedBox(height: 10),
                    for (final issue in warnings) ...[
                      _IssueTile(issue: issue),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.color, required this.label});

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return StatusChip(label: label, color: color, icon: icon);
  }
}

class _IssueTile extends ConsumerStatefulWidget {
  const _IssueTile({required this.issue});

  final DoctorIssue issue;

  @override
  ConsumerState<_IssueTile> createState() => _IssueTileState();
}

class _IssueTileState extends ConsumerState<_IssueTile> {
  DoctorFix? _running;

  Future<void> _apply(DoctorFix fix) async {
    final issue = widget.issue;
    final actions = ref.read(doctorActionsProvider);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _running = fix);
    String? message;
    try {
      message = switch (fix) {
        DoctorFix.turnOffSigning => await actions.turnOffSigning(issue.profileId!),
        DoctorFix.unlinkSshKey => await actions.unlinkSshKey(issue.profileId!),
        DoctorFix.deleteRule => await actions.deleteRule(issue.ruleId!),
        DoctorFix.installCli => await actions.installCli(),
        DoctorFix.useCompanyProfile => await actions.useCompanyProfile(issue),
        DoctorFix.signIn => await _signIn(issue.profileId!),
        DoctorFix.setUpSshKey => await _openProfile(issue.profileId!),
      };
    } catch (e) {
      message = "That didn't work: ${e is StateError ? e.message : e}";
    } finally {
      if (mounted) setState(() => _running = null);
    }
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 6)));
    }
  }

  /// Runs GitHub sign-in for the profile; without a built-in sign-in app,
  /// opens the profile so a token can be pasted.
  Future<String?> _signIn(String profileId) async {
    final flow = ref.read(gitHubDeviceFlowProvider);
    if (flow == null) return _openProfile(profileId);
    final profile = await _findProfile(profileId);
    if (!mounted) return null;
    final result = await showDialog<GitHubSignInResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GitHubSignInDialog(flow: flow, expectedLogin: profile.githubLogin),
    );
    if (result == null) return null;
    return ref
        .read(doctorActionsProvider)
        .saveSignIn(profileId, token: result.token, login: result.account.login);
  }

  Future<String?> _openProfile(String profileId) async {
    final profile = await _findProfile(profileId);
    if (!mounted) return null;
    await showProfileEditor(context, profile);
    ref.invalidate(doctorIssuesProvider);
    return null;
  }

  Future<Profile> _findProfile(String id) async {
    final profiles = await ref.read(profilesProvider.future);
    return profiles.firstWhere(
      (p) => p.id == id,
      orElse: () => throw StateError('That profile no longer exists.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final issue = widget.issue;
    final blocking = issue.severity == Severity.blocking;
    final color = blocking ? GitaColors.red : GitaColors.amber;
    final fixes = fixesFor(issue);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                blocking ? Icons.close_rounded : Icons.priority_high_rounded,
                color: color,
                size: 18,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(issue.message, style: Theme.of(context).textTheme.bodyMedium),
            ),
            for (final (i, fix) in fixes.indexed) ...[
              const SizedBox(width: 10),
              _FixButton(
                label: fix.label,
                primary: i == 0,
                running: _running == fix,
                onPressed: _running == null ? () => _apply(fix) : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FixButton extends StatelessWidget {
  const _FixButton({
    required this.label,
    required this.primary,
    required this.running,
    required this.onPressed,
  });

  final String label;
  final bool primary;
  final bool running;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final child = running
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(label);
    return primary
        ? FilledButton.tonal(onPressed: onPressed, child: child)
        : TextButton(onPressed: onPressed, child: child);
  }
}
