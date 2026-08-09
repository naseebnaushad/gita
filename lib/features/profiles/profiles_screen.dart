import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/theme.dart';
import '../../core/models/profile.dart';
import '../../core/providers.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/initials_avatar.dart';
import '../../widgets/screen_header.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenHeader(
          title: 'Profiles',
          subtitle: 'Git identities you can assign to folders.',
          actions: [
            FilledButton.icon(
              onPressed: () => _openEditor(context, ref, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New profile'),
            ),
          ],
        ),
        Expanded(
          child: profilesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Failed to load profiles: $e')),
            data: (profiles) {
              if (profiles.isEmpty) {
                return EmptyState(
                  icon: Icons.badge_outlined,
                  title: 'No profiles yet',
                  message: 'Create one for each Git identity (e.g. Work, '
                      'Personal) to start assigning folders to it.',
                  actionLabel: 'New profile',
                  onAction: () => _openEditor(context, ref, null),
                );
              }
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 340,
                  mainAxisExtent: 152,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: profiles.length,
                itemBuilder: (context, i) {
                  final profile = profiles[i];
                  return _ProfileCard(
                    profile: profile,
                    onEdit: () => _openEditor(context, ref, profile),
                    onDelete: () => _confirmDelete(context, ref, profile),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, Profile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('This removes "${profile.label}". Rules pointing at it will '
            'stop resolving until reassigned.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(profilesProvider.notifier).delete(profile.id);
    }
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref, Profile? existing) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ProfileEditorDialog(existing: existing),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.onEdit,
    required this.onDelete,
  });

  final Profile profile;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = Color(profile.colorArgb);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  InitialsAvatar(label: profile.label, color: color, radius: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          profile.label,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          profile.gitName,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, size: 18, color: scheme.onSurfaceVariant),
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.alternate_email, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      profile.gitEmail,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (profile.signCommitsByDefault)
                    Tooltip(
                      message: 'Signs commits by default',
                      child: Icon(Icons.verified_user_outlined, size: 15, color: scheme.primary),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileEditorDialog extends ConsumerStatefulWidget {
  const _ProfileEditorDialog({this.existing});

  final Profile? existing;

  @override
  ConsumerState<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends ConsumerState<_ProfileEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _labelController;
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _tokenController;
  late bool _signByDefault;
  late int _colorArgb;
  bool _hadStoredToken = false;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _labelController = TextEditingController(text: e?.label ?? '');
    _nameController = TextEditingController(text: e?.gitName ?? '');
    _emailController = TextEditingController(text: e?.gitEmail ?? '');
    _tokenController = TextEditingController();
    _signByDefault = e?.signCommitsByDefault ?? false;
    _colorArgb = e?.colorArgb ?? profileColorPalette[0];
    if (e != null) {
      ref.read(secureTokenServiceProvider).readToken(e.id).then((token) {
        if (!mounted || token == null) return;
        setState(() {
          _tokenController.text = token;
          _hadStoredToken = true;
        });
      });
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          InitialsAvatar(
            label: _labelController.text.isEmpty ? '?' : _labelController.text,
            color: Color(_colorArgb),
            radius: 16,
          ),
          const SizedBox(width: 12),
          Text(isNew ? 'New profile' : 'Edit profile'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _labelController,
                decoration: const InputDecoration(labelText: 'Label (e.g. Work)'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Git user.name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Git user.email'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (!v.contains('@')) return 'Not a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _tokenController,
                obscureText: _obscureToken,
                decoration: InputDecoration(
                  labelText: 'Access token (optional, for HTTPS remotes)',
                  helperText: 'Stored in the OS keychain, never in plain files.',
                  suffixIcon: IconButton(
                    icon: Icon(_obscureToken ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscureToken = !_obscureToken),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sign commits by default'),
                value: _signByDefault,
                onChanged: (v) => setState(() => _signByDefault = v),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 10,
                  children: [
                    for (final c in profileColorPalette)
                      GestureDetector(
                        onTap: () => setState(() => _colorArgb = c),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: _colorArgb == c ? 32 : 28,
                          height: _colorArgb == c ? 32 : 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(c),
                            border: _colorArgb == c
                                ? Border.all(color: scheme.onSurface, width: 2)
                                : null,
                          ),
                          child: _colorArgb == c
                              ? const Icon(Icons.check, size: 16, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
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
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing;
    final profile = Profile(
      id: existing?.id ?? const Uuid().v4(),
      label: _labelController.text.trim(),
      gitName: _nameController.text.trim(),
      gitEmail: _emailController.text.trim(),
      sshKeyId: existing?.sshKeyId,
      gpgKeyId: existing?.gpgKeyId,
      signCommitsByDefault: _signByDefault,
      colorArgb: _colorArgb,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
    await ref.read(profilesProvider.notifier).upsert(profile);

    final tokenService = ref.read(secureTokenServiceProvider);
    final token = _tokenController.text.trim();
    if (token.isNotEmpty) {
      await tokenService.saveToken(profile.id, token);
    } else if (_hadStoredToken) {
      await tokenService.deleteToken(profile.id);
    }

    if (mounted) Navigator.pop(context);
  }
}
