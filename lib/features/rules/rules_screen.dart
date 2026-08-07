import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/profile.dart';
import '../../core/models/repo_rule.dart';
import '../../core/providers.dart';
import '../../core/services/path_resolver.dart';

class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(repoRulesProvider);
    final profilesAsync = ref.watch(profilesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rules'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New rule',
            onPressed: profilesAsync.valueOrNull == null || profilesAsync.value!.isEmpty
                ? null
                : () => _openEditor(context, ref, null, profilesAsync.value!),
          ),
        ],
      ),
      body: rulesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load rules: $e')),
        data: (rules) {
          final profiles = profilesAsync.valueOrNull ?? [];
          if (profiles.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Create a profile first, then assign folders to it here.'),
              ),
            );
          }
          if (rules.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No rules yet. Add one to map a folder to a profile.'),
              ),
            );
          }
          final byId = {for (final p in profiles) p.id: p};
          final sorted = [...rules]
            ..sort((a, b) => a.pathPattern.compareTo(b.pathPattern));
          return ListView.separated(
            itemCount: sorted.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final rule = sorted[i];
              final profile = byId[rule.profileId];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor:
                      profile != null ? Color(profile.colorArgb) : Colors.grey,
                ),
                title: Text(rule.pathPattern),
                subtitle: Text(profile?.label ?? 'Unknown profile'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _openEditor(context, ref, rule, profiles),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => ref.read(repoRulesProvider.notifier).delete(rule.id),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
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
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _pathController,
                      decoration: const InputDecoration(labelText: 'Folder path'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: 'Browse',
                    onPressed: _pickFolder,
                  ),
                ],
              ),
              DropdownButtonFormField<String>(
                initialValue: _profileId,
                decoration: const InputDecoration(labelText: 'Profile'),
                items: [
                  for (final p in widget.profiles)
                    DropdownMenuItem(value: p.id, child: Text(p.label)),
                ],
                onChanged: (v) => setState(() => _profileId = v),
              ),
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
