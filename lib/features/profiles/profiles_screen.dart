import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/profile.dart';
import '../../core/providers.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profilesAsync = ref.watch(profilesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profiles'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New profile',
            onPressed: () => _openEditor(context, ref, null),
          ),
        ],
      ),
      body: profilesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load profiles: $e')),
        data: (profiles) {
          if (profiles.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            itemCount: profiles.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final profile = profiles[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(profile.colorArgb),
                ),
                title: Text(profile.label),
                subtitle: Text('${profile.gitName} <${profile.gitEmail}>'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _openEditor(context, ref, profile),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmDelete(context, ref, profile),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No profiles yet. Create one for each Git identity (e.g. Work, '
          'Personal) to start assigning folders to it.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

const _palette = [
  0xFF3D5AFE,
  0xFF00BFA5,
  0xFFFF6D00,
  0xFFD500F9,
  0xFFC51162,
  0xFF64DD17,
];

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
    _colorArgb = e?.colorArgb ?? _palette[0];
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
    return AlertDialog(
      title: Text(isNew ? 'New profile' : 'Edit profile'),
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
              ),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Git user.name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Git user.email'),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  if (!v.contains('@')) return 'Not a valid email';
                  return null;
                },
              ),
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
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sign commits by default'),
                value: _signByDefault,
                onChanged: (v) => setState(() => _signByDefault = v),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final c in _palette)
                      GestureDetector(
                        onTap: () => setState(() => _colorArgb = c),
                        child: CircleAvatar(
                          radius: 14,
                          backgroundColor: Color(c),
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
