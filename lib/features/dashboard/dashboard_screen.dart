import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/mismatch_report.dart';
import '../../core/models/profile.dart';
import '../../core/models/repo_rule.dart';
import '../../core/models/ssh_key.dart';
import '../../core/models/tracked_repo.dart';
import '../../core/providers.dart';
import '../../core/services/doctor_fixes.dart';
import '../../core/services/git_service.dart';
import '../../core/services/mismatch_detector.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/initials_avatar.dart';
import '../../widgets/screen_header.dart';
import '../../widgets/status_chip.dart';
import '../setup/setup_wizard.dart';
import 'clone_dialog.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reposAsync = ref.watch(trackedReposProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenHeader(
          title: 'Dashboard',
          subtitle: 'Tracked repositories and their resolved identity.',
          actions: [
            OutlinedButton.icon(
              onPressed: () => _clone(context),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Clone a project'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => _addRepo(context, ref),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: const Text('Add repo'),
            ),
          ],
        ),
        Expanded(
          child: reposAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, st) => Center(child: Text('Failed to load repos: $e')),
            data: (repos) {
              if (repos.isEmpty) {
                return EmptyState(
                  icon: Icons.folder_off_outlined,
                  title: 'No repos tracked yet',
                  message: 'Let Gita find the projects on this computer and set '
                      'up the right account for each, or add one yourself.',
                  actionLabel: 'Scan this computer',
                  onAction: () => showSetupWizard(context),
                  secondaryLabel: 'Add one project',
                  onSecondary: () => _addRepo(context, ref),
                );
              }
              return _RepoList(repos: repos);
            },
          ),
        ),
      ],
    );
  }

  Future<void> _clone(BuildContext context) async {
    final outcome = await showCloneDialog(context);
    if (outcome == null || !context.mounted) return;
    final extra = [
      if (outcome.addedRule) 'Added a rule so it always uses this account.',
      if (outcome.guardProblem != null) 'Safety check not added: ${outcome.guardProblem}',
    ].join(' ');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${outcome.message} $extra'.trim()), duration: const Duration(seconds: 8)),
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
    final guard = await ref.read(trackedReposProvider.notifier).add(top);
    if (!guard.ok && guard.message != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(guard.message!), duration: const Duration(seconds: 8)),
      );
    }
  }
}

class _RepoList extends ConsumerWidget {
  const _RepoList({required this.repos});

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
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      children: [
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    _headerCell('REPOSITORY', flex: 4),
                    _headerCell('PROFILE', flex: 2),
                    _headerCell('EFFECTIVE EMAIL', flex: 3),
                    _headerCell('REMOTE', flex: 3),
                    _headerCell('STATUS', flex: 2, alignEnd: true),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              for (var i = 0; i < repos.length; i++) ...[
                if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
                _RepoRow(
                  repo: repos[i],
                  rules: rules,
                  profilesById: profilesById,
                  sshKeysById: sshKeysById,
                  detector: detector,
                  git: git,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _headerCell(String label, {required int flex, bool alignEnd = false}) {
    return Expanded(
      flex: flex,
      child: Align(
        alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
        child: Builder(builder: (context) {
          return Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 0.6,
                ),
          );
        }),
      ),
    );
  }
}

class _RepoRow extends StatelessWidget {
  const _RepoRow({
    required this.repo,
    required this.rules,
    required this.profilesById,
    required this.sshKeysById,
    required this.detector,
    required this.git,
  });

  final TrackedRepo repo;
  final List<RepoRule> rules;
  final Map<String, Profile> profilesById;
  final Map<String, SshKey> sshKeysById;
  final MismatchDetector detector;
  final GitService git;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matched = RepoRule.bestMatchFor(repo.path, rules);
    final profile = matched != null ? profilesById[matched.profileId] : null;
    final name = repo.path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ?? repo.path;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Row(
              children: [
                Icon(Icons.folder_rounded, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        repo.path,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: profile == null
                ? Text('—', style: TextStyle(color: scheme.onSurfaceVariant))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InitialsAvatar(label: profile.label, color: Color(profile.colorArgb), radius: 11),
                      const SizedBox(width: 8),
                      Flexible(child: Text(profile.label, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
          ),
          Expanded(
            flex: 3,
            child: FutureBuilder<String?>(
              future: git.getConfigValue(repo.path, 'user.email'),
              builder: (context, snapshot) => Text(
                snapshot.data ?? '—',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: FutureBuilder<String?>(
              future: git.getRemoteUrl(repo.path),
              builder: (context, snapshot) => Text(
                snapshot.data ?? '—',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: _StatusIndicator(
                repoPath: repo.path,
                rules: rules,
                profilesById: profilesById,
                sshKeysById: sshKeysById,
                detector: detector,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusIndicator extends ConsumerStatefulWidget {
  const _StatusIndicator({
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
  ConsumerState<_StatusIndicator> createState() => _StatusIndicatorState();
}

class _StatusIndicatorState extends ConsumerState<_StatusIndicator> {
  bool _fixing = false;

  Future<(MismatchReport?, RepoFix?)> _check() async {
    final report = await widget.detector.check(
      repoPath: widget.repoPath,
      rules: widget.rules,
      profilesById: widget.profilesById,
      sshKeysById: widget.sshKeysById,
    );
    if (report == null) return (null, null);
    return (report, await ref.read(repoFixerProvider).fixFor(report));
  }

  Future<void> _fix(RepoFix fix) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _fixing = true);
    String message;
    try {
      message = await ref.read(doctorActionsProvider).applyRepoFix(widget.repoPath, fix);
    } catch (e) {
      message = "That didn't work: ${e is GitServiceException ? e.message : e}";
    }
    if (mounted) setState(() => _fixing = false);
    messenger.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 6)));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(MismatchReport?, RepoFix?)>(
      future: _check(),
      builder: (context, snapshot) {
        if (_fixing || (!snapshot.hasData && snapshot.connectionState != ConnectionState.done)) {
          return const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        }
        final (report, fix) = snapshot.data ?? (null, null);
        if (report == null) {
          return const StatusDot(
            icon: Icons.check_rounded,
            color: Color(0xFF22C55E),
            tooltip: 'Identity matches expected profile',
          );
        }
        final blocking = report.severity == Severity.blocking;
        final dot = StatusDot(
          icon: blocking ? Icons.close_rounded : Icons.priority_high_rounded,
          color: blocking ? const Color(0xFFEF4444) : const Color(0xFFF59E0B),
          tooltip: report.detail,
        );
        if (fix == null) return dot;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: ValueKey('fix-${widget.repoPath}'),
              tooltip: '${fix.label}\n${report.detail}',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.build_rounded),
              onPressed: () => _fix(fix),
            ),
            dot,
          ],
        );
      },
    );
  }
}
