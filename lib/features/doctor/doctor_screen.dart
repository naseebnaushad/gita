import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/doctor_issue.dart';
import '../../core/models/mismatch_report.dart' show Severity;
import '../../core/providers.dart';
import '../../widgets/empty_state.dart';
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

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue});

  final DoctorIssue issue;

  @override
  Widget build(BuildContext context) {
    final blocking = issue.severity == Severity.blocking;
    final color = blocking ? GitaColors.red : GitaColors.amber;
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
          ],
        ),
      ),
    );
  }
}
