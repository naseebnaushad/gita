import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/mismatch_report.dart';
import '../../core/models/profile.dart';
import '../../core/models/repo_rule.dart';
import '../../core/models/ssh_key.dart';
import '../../core/models/tracked_repo.dart';
import '../../core/providers.dart';
import '../../core/services/git_service.dart';
import '../../core/services/mismatch_detector.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reposAsync = ref.watch(trackedReposProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Add repo',
            onPressed: () => _addRepo(context, ref),
          ),
        ],
      ),
      body: reposAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Failed to load repos: $e')),
        data: (repos) {
          if (repos.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No repos tracked yet. Use "Add repo" to register one, or '
                  'assign a Rule to a folder and add repos under it.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return _RepoTable(repos: repos);
        },
      ),
    );
  }

  Future<void> _addRepo(BuildContext context, WidgetRef ref) async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    final git = ref.read(gitServiceProvider);
    if (!await git.isGitRepo(dir)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$dir is not a git repository.')),
        );
      }
      return;
    }
    final top = await git.topLevel(dir) ?? dir;
    await ref.read(trackedReposProvider.notifier).add(top);
  }
}

class _RepoTable extends ConsumerWidget {
  const _RepoTable({required this.repos});

  final List<TrackedRepo> repos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(repoRulesProvider);
    final profilesAsync = ref.watch(profilesProvider);
    final sshKeysAsync = ref.watch(sshKeysProvider);

    if (!rulesAsync.hasValue || !profilesAsync.hasValue || !sshKeysAsync.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    final rules = rulesAsync.value!;
    final profilesById = {for (final p in profilesAsync.value!) p.id: p};
    final sshKeysById = {for (final k in sshKeysAsync.value!) k.id: k};
    final detector = ref.watch(mismatchDetectorProvider);
    final git = ref.watch(gitServiceProvider);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Repo')),
          DataColumn(label: Text('Profile')),
          DataColumn(label: Text('Effective email')),
          DataColumn(label: Text('Remote')),
          DataColumn(label: Text('Status')),
        ],
        rows: [
          for (final repo in repos)
            DataRow(
              cells: [
                DataCell(Text(repo.path, overflow: TextOverflow.ellipsis)),
                DataCell(_ProfileCell(repoPath: repo.path, rules: rules, profilesById: profilesById)),
                DataCell(_EmailCell(repoPath: repo.path, git: git)),
                DataCell(_RemoteCell(repoPath: repo.path, git: git)),
                DataCell(_StatusCell(
                  repoPath: repo.path,
                  rules: rules,
                  profilesById: profilesById,
                  sshKeysById: sshKeysById,
                  detector: detector,
                )),
              ],
            ),
        ],
      ),
    );
  }
}

class _ProfileCell extends StatelessWidget {
  const _ProfileCell({required this.repoPath, required this.rules, required this.profilesById});

  final String repoPath;
  final List<RepoRule> rules;
  final Map<String, Profile> profilesById;

  @override
  Widget build(BuildContext context) {
    final matched = RepoRule.bestMatchFor(repoPath, rules);
    if (matched == null) return const Text('—');
    final profile = profilesById[matched.profileId];
    return Text(profile?.label ?? 'Unknown');
  }
}

class _EmailCell extends StatelessWidget {
  const _EmailCell({required this.repoPath, required this.git});

  final String repoPath;
  final GitService git;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: git.getConfigValue(repoPath, 'user.email'),
      builder: (context, snapshot) => Text(snapshot.data ?? '—'),
    );
  }
}

class _RemoteCell extends StatelessWidget {
  const _RemoteCell({required this.repoPath, required this.git});

  final String repoPath;
  final GitService git;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: git.getRemoteUrl(repoPath),
      builder: (context, snapshot) => Text(
        snapshot.data ?? '—',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _StatusCell extends StatelessWidget {
  const _StatusCell({
    required this.repoPath,
    required this.rules,
    required this.profilesById,
    required this.sshKeysById,
    required this.detector,
  });

  final String repoPath;
  final List<RepoRule> rules;
  final Map<String, Profile> profilesById;
  final Map<String, SshKey> sshKeysById;
  final MismatchDetector detector;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MismatchReport?>(
      future: detector.check(
        repoPath: repoPath,
        rules: rules,
        profilesById: profilesById,
        sshKeysById: sshKeysById,
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData && snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        final report = snapshot.data;
        if (report == null) {
          return const Tooltip(message: 'Identity matches expected profile', child: Icon(Icons.check_circle, color: Colors.green));
        }
        final icon = report.severity == Severity.blocking
            ? Icons.cancel
            : Icons.warning_amber;
        final color = report.severity == Severity.blocking ? Colors.red : Colors.orange;
        return Tooltip(
          message: report.detail,
          child: Icon(icon, color: color),
        );
      },
    );
  }
}
