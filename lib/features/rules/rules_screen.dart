import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/profile.dart';
import '../../core/models/repo_rule.dart';
import '../../core/providers.dart';
import '../../core/services/path_resolver.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/initials_avatar.dart';
import '../../widgets/screen_header.dart';

class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(repoRulesProvider);
    final profilesAsync = ref.watch(profilesProvider);
    final canCreate = profilesAsync.valueOrNull != null && profilesAsync.value!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenHeader(
          title: 'Rules',
          subtitle: 'Map a folder to the profile Git should use inside it.',
          actions: [
            FilledButton.icon(
              onPressed: canCreate ? () => _openEditor(context, ref, null, profilesAsync.value!) : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New rule'),
            ),
          ],
        ),
        Expanded(
          child: rulesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Failed to load rules: $e')),
            data: (rules) {
              final profiles = profilesAsync.valueOrNull ?? [];
              if (profiles.isEmpty) {
                return const EmptyState(
                  icon: Icons.badge_outlined,
                  title: 'Create a profile first',
                  message: 'Rules assign folders to a profile — add a profile, '
                      'then come back here to map folders to it.',
                );
              }
              if (rules.isEmpty) {
                return EmptyState(
                  icon: Icons.rule_folder_outlined,
                  title: 'No rules yet',
                  message: 'Add one to map a folder to a profile.',
                  actionLabel: 'New rule',
                  onAction: () => _openEditor(context, ref, null, profiles),
                );
              }
              final byId = {for (final p in profiles) p.id: p};
              final sorted = [...rules]
                ..sort((a, b) => a.pathPattern.compareTo(b.pathPattern));
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                itemCount: sorted.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final rule = sorted[i];
                  final profile = byId[rule.profileId];
                  return _RuleCard(
                    rule: rule,
                    profile: profile,
                    onEdit: () => _openEditor(context, ref, rule, profiles),
                    onDelete: () => ref.read(repoRulesProvider.notifier).delete(rule.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    RepoRule? existing,
    List<Profile> profiles,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _RuleEditorDialog(existing: existing, profiles: profiles),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.profile,
    required this.onEdit,
    required this.onDelete,
  });

  final RepoRule rule;
  final Profile? profile;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  rule.pathPattern,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              if (profile != null) ...[
                InitialsAvatar(label: profile!.label, color: Color(profile!.colorArgb), radius: 12),
                const SizedBox(width: 8),
                Text(profile!.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              ] else
                Chip(
                  label: const Text('Unknown profile'),
                  backgroundColor: scheme.errorContainer,
                ),
              if (rule.priority != 0) ...[
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'priority ${rule.priority}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: onEdit,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuleEditorDialog extends ConsumerStatefulWidget {
  const _RuleEditorDialog({this.existing, required this.profiles});

  final RepoRule? existing;
  final List<Profile> profiles;

  @override
  ConsumerState<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends ConsumerState<_RuleEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pathController;
  late final TextEditingController _priorityController;
  String? _profileId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _pathController = TextEditingController(text: e?.pathPattern ?? '');
    _priorityController = TextEditingController(text: (e?.priority ?? 0).toString());
    _profileId = e?.profileId ?? widget.profiles.first.id;
  }

  @override
  void dispose() {
    _pathController.dispose();
    _priorityController.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath();
    if (dir != null) {
      setState(() => _pathController.text = dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'New rule' : 'Edit rule'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _pathController,
                      decoration: const InputDecoration(labelText: 'Folder path'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.folder_open),
                    tooltip: 'Browse',
                    onPressed: _pickFolder,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _profileId,
                decoration: const InputDecoration(labelText: 'Profile'),
                items: [
                  for (final p in widget.profiles)
                    DropdownMenuItem(
                      value: p.id,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InitialsAvatar(label: p.label, color: Color(p.colorArgb), radius: 10),
                          const SizedBox(width: 8),
                          Text(p.label),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _profileId = v),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _priorityController,
                decoration: const InputDecoration(
                  labelText: 'Priority (tiebreaker for equal-length paths)',
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _profileId == null) return;
    final existing = widget.existing;
    final rule = RepoRule(
      id: existing?.id ?? const Uuid().v4(),
      pathPattern: resolveRepoPath(_pathController.text.trim()),
      profileId: _profileId!,
      priority: int.tryParse(_priorityController.text.trim()) ?? 0,
    );
    await ref.read(repoRulesProvider.notifier).upsert(rule);
    if (mounted) Navigator.pop(context);
  }
}
