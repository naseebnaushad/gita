import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/profile.dart';
import '../../core/models/repo_rule.dart';
import '../../core/providers.dart';
import '../../core/services/company_setup.dart';
import '../../core/services/path_resolver.dart';
import '../../core/services/remote_url.dart';
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
          subtitle:
              'Choose which profile a project uses: by the folder it is in, '
              'or by the GitHub organization it comes from.',
          actions: [
            OutlinedButton.icon(
              onPressed: canCreate ? () => _importCompany(context) : null,
              icon: const Icon(Icons.business_outlined, size: 18),
              label: const Text('Import company setup'),
            ),
            const SizedBox(width: 8),
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
                  message:
                      'Rules pick a profile for your projects. Add a profile, then come back here.',
                );
              }
              if (rules.isEmpty) {
                return EmptyState(
                  icon: Icons.rule_folder_outlined,
                  title: 'No rules yet',
                  message:
                      "Add one to say which profile a folder, or a GitHub organization's "
                      'projects, should use.',
                  actionLabel: 'New rule',
                  onAction: () => _openEditor(context, ref, null, profiles),
                );
              }
              final byId = {for (final p in profiles) p.id: p};
              // Organization rules first: they win over folder rules.
              final sorted = [...rules]
                ..sort((a, b) {
                  if (a.isAccountRule != b.isAccountRule) {
                    return a.isAccountRule ? -1 : 1;
                  }
                  return a.describe.toLowerCase().compareTo(
                    b.describe.toLowerCase(),
                  );
                });
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

  Future<void> _importCompany(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Company setup', extensions: ['json']),
      ],
      confirmButtonText: 'Import',
    );
    if (file == null) return;
    final CompanySetup setup;
    try {
      setup = CompanySetup.parse(await File(file.path).readAsString());
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on FileSystemException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't read that file: ${e.message}")),
      );
      return;
    }
    if (!context.mounted) return;
    final message = await showCompanyImportDialog(context, setup);
    if (message != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
    }
  }
}

/// Asks which profile is the work one, then imports [setup]. Returns what
/// happened, in a sentence, or null if cancelled.
Future<String?> showCompanyImportDialog(
  BuildContext context,
  CompanySetup setup,
) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => CompanyImportDialog(setup: setup),
);

class CompanyImportDialog extends ConsumerStatefulWidget {
  const CompanyImportDialog({super.key, required this.setup});

  final CompanySetup setup;

  @override
  ConsumerState<CompanyImportDialog> createState() =>
      _CompanyImportDialogState();
}

class _CompanyImportDialogState extends ConsumerState<CompanyImportDialog> {
  String? _profileId;
  bool _picked = false;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    final profiles =
        ref.watch(profilesProvider).valueOrNull ?? const <Profile>[];
    if (!_picked && profiles.isNotEmpty) {
      _picked = true;
      _profileId = CompanyService.pickProfile(setup, profiles)?.id;
    }
    final profile = profiles.where((p) => p.id == _profileId).firstOrNull;
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final domains = setup.emailDomains.map((d) => '@$d').join(' or ');
    final wrongEmail =
        profile != null &&
        setup.emailDomains.isNotEmpty &&
        !setup.isCompanyEmail(profile.gitEmail);

    return AlertDialog(
      title: Text('Set up ${setup.name}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Projects from these GitHub organizations will use your work '
              'profile, wherever they are on this computer:',
              style: muted,
            ),
            const SizedBox(height: 8),
            for (final o in setup.owners)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    const Icon(Icons.business_outlined, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      '${setup.host}/$o',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('company-profile-$_profileId'),
              initialValue: _profileId,
              decoration: const InputDecoration(labelText: 'Your work profile'),
              items: [
                for (final p in profiles)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text('${p.label}  <${p.gitEmail}>'),
                  ),
              ],
              onChanged: _busy ? null : (id) => setState(() => _profileId = id),
            ),
            if (profile == null && setup.emailDomains.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                setup.companyProfiles(profiles).isEmpty
                    ? 'None of your profiles uses a $domains email. Pick the one '
                          'for ${setup.name}, or add a work profile under Profiles first.'
                    : 'Pick which profile is your ${setup.name} one.',
                style: muted,
              ),
            ],
            if (wrongEmail) ...[
              const SizedBox(height: 12),
              Text(
                '"${profile.label}" commits as ${profile.gitEmail}, not a $domains '
                'email. ${setup.name} may not accept those commits.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || profile == null ? null : () => _import(profile),
          child: const Text('Set it up'),
        ),
      ],
    );
  }

  Future<void> _import(Profile profile) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(companyActionsProvider)
          .import(widget.setup, profile);
      if (mounted) Navigator.of(context).pop(result.message(widget.setup));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "That didn't work: $e";
        });
      }
    }
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
              Icon(
                rule.isAccountRule
                    ? Icons.business_outlined
                    : Icons.folder_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: rule.isAccountRule
                    ? Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'Projects from '),
                            TextSpan(
                              text: rule.describe,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                      )
                    : Text(
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
              if (rule.priority != 0 && !rule.isAccountRule) ...[
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
                tooltip: 'Edit',
                onPressed: onEdit,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Delete',
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
  late final TextEditingController _ownerController;
  late final TextEditingController _priorityController;
  String? _profileId;
  late bool _byAccount;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _byAccount = e?.isAccountRule ?? false;
    _pathController = TextEditingController(text: e?.pathPattern ?? '');
    _ownerController = TextEditingController(
      text: e == null || !e.isAccountRule
          ? ''
          : (e.host == RepoRule.defaultHost ? e.githubOwner! : e.describe),
    );
    _priorityController = TextEditingController(
      text: (e?.priority ?? 0).toString(),
    );
    _profileId = e?.profileId ?? widget.profiles.first.id;
  }

  @override
  void dispose() {
    _pathController.dispose();
    _ownerController.dispose();
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
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isNew) ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.folder_outlined),
                      label: Text('A folder'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.business_outlined),
                      label: Text('A GitHub organization'),
                    ),
                  ],
                  selected: {_byAccount},
                  onSelectionChanged: (s) =>
                      setState(() => _byAccount = s.first),
                ),
                const SizedBox(height: 14),
              ],
              if (_byAccount)
                TextFormField(
                  controller: _ownerController,
                  decoration: const InputDecoration(
                    labelText: 'GitHub organization or account',
                    hintText: 'acme',
                    helperText:
                        'Every project from github.com/<this name>/… uses the '
                        'profile below, wherever it is on this computer.',
                    helperMaxLines: 2,
                  ),
                  validator: (v) => parseOwnerInput(v ?? '') == null
                      ? 'Type the name from the project address, e.g. acme in github.com/acme/api'
                      : null,
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _pathController,
                        decoration: const InputDecoration(
                          labelText: 'Folder path',
                        ),
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
              if (!_byAccount) ...[
                const SizedBox(height: 14),
                TextFormField(
                  controller: _priorityController,
                  decoration: const InputDecoration(
                    labelText: 'Priority (tiebreaker for equal-length paths)',
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
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
    final id = existing?.id ?? const Uuid().v4();
    final owner = parseOwnerInput(_ownerController.text);
    final rule = _byAccount
        ? RepoRule.account(
            id: id,
            owner: owner!.owner,
            host: owner.host,
            profileId: _profileId!,
          )
        : RepoRule(
            id: id,
            pathPattern: resolveRepoPath(_pathController.text.trim()),
            profileId: _profileId!,
            priority: int.tryParse(_priorityController.text.trim()) ?? 0,
          );
    await ref.read(repoRulesProvider.notifier).upsert(rule);
    if (mounted) Navigator.pop(context);
  }
}

/// Reads what someone typed for an organization rule: `acme`,
/// `github.com/acme`, or a project address such as
/// `https://github.com/acme/api.git`. Null if it isn't one of those.
({String host, String owner})? parseOwnerInput(String input) {
  var t = input.trim();
  if (t.isEmpty || t.contains(' ')) return null;
  final valid = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$');
  if (!t.contains('/') && !t.contains(':')) {
    return valid.hasMatch(t) ? (host: RepoRule.defaultHost, owner: t) : null;
  }
  if (!t.contains('://') && !t.contains('@')) t = 'https://$t';
  final remote = RemoteUrl.parse(t);
  final owner = remote?.path.split('/').where((s) => s.isNotEmpty).firstOrNull;
  if (remote == null || owner == null || !valid.hasMatch(owner)) return null;
  return (host: remote.host, owner: owner);
}
