import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/doctor_issue.dart';
import '../../core/models/mismatch_report.dart' show Severity;
import '../../core/providers.dart';

class DoctorScreen extends ConsumerWidget {
  const DoctorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issuesAsync = ref.watch(doctorIssuesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Doctor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-run checks',
            onPressed: () => ref.invalidate(doctorIssuesProvider),
          ),
        ],
      ),
      body: issuesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to run checks: $e')),
        data: (issues) {
          if (issues.isEmpty) {
            return const _AllClearState();
          }
          final blocking = issues.where((i) => i.severity == Severity.blocking).toList();
          final warnings = issues.where((i) => i.severity == Severity.warning).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Checks the setup itself for problems that would otherwise '
                'only show up as a failed commit or push — e.g. a profile '
                'with signing enabled but no matching key on this machine.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (blocking.isNotEmpty) ...[
                _SectionHeader(
                  icon: Icons.cancel,
                  color: Colors.red,
                  label: '${blocking.length} would block a commit',
                ),
                for (final issue in blocking) _IssueTile(issue: issue),
                const SizedBox(height: 16),
              ],
              if (warnings.isNotEmpty) ...[
                _SectionHeader(
                  icon: Icons.warning_amber,
                  color: Colors.orange,
                  label: '${warnings.length} configuration warning(s)',
                ),
                for (final issue in warnings) _IssueTile(issue: issue),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _AllClearState extends StatelessWidget {
  const _AllClearState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 40),
            SizedBox(height: 12),
            Text(
              'No issues found. Profiles, rules, and keys are consistent.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue});

  final DoctorIssue issue;

  @override
  Widget build(BuildContext context) {
    final blocking = issue.severity == Severity.blocking;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          blocking ? Icons.cancel : Icons.warning_amber,
          color: blocking ? Colors.red : Colors.orange,
        ),
        title: Text(issue.message),
      ),
    );
  }
}
