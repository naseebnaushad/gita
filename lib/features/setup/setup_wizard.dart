import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/models/profile.dart';
import '../../core/providers.dart';
import '../../core/services/machine_scanner.dart';
import '../../core/services/path_resolver.dart';
import '../profiles/github_sign_in_dialog.dart';

/// Opens the setup wizard. Returns true if it set anything up.
Future<bool> showSetupWizard(BuildContext context) async {
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const SetupWizard(),
  );
  return done ?? false;
}

enum _Step { intro, scanning, review, applying, done }

/// One suggested profile as the person edits it in the review step.
class _Draft {
  _Draft(this.suggestion)
      : label = TextEditingController(text: suggestion.label),
        name = TextEditingController(text: suggestion.name),
        email = TextEditingController(text: suggestion.email),
        sshKey = suggestion.sshKey,
        folders = {...suggestion.folders};

  final ProfileSuggestion suggestion;
  final TextEditingController label;
  final TextEditingController name;
  final TextEditingController email;
  FoundSshKey? sshKey;
  final Set<String> folders;
  bool include = true;

  bool get existing => suggestion.existingProfileId != null;

  void dispose() {
    label.dispose();
    name.dispose();
    email.dispose();
  }

  SetupChoice toChoice() {
    bool under(String path, String folder) {
      final a = path.toLowerCase();
      final b = folder.toLowerCase();
      return a == b || a.startsWith('$b/');
    }

    return SetupChoice(
      label: label.text,
      name: name.text,
      email: email.text,
      folders: [...folders],
      sshKey: sshKey,
      githubLogin: suggestion.githubLogin,
      existingProfileId: suggestion.existingProfileId,
      projects: [
        for (final r in suggestion.repos)
          if (folders.any((f) => under(r.path, f))) r.path,
      ],
    );
  }
}

/// Looks around the computer for the accounts its projects use and sets up
/// profiles and folder rules from them, in a few plain steps.
class SetupWizard extends ConsumerStatefulWidget {
  const SetupWizard({super.key});

  @override
  ConsumerState<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends ConsumerState<SetupWizard> {
  _Step _step = _Step.intro;
  late List<String> _folders;
  MachineScan? _scan;
  List<_Draft> _drafts = [];
  bool _trackProjects = true;
  SetupResult? _result;
  String? _error;
  final Set<String> _signedIn = {};

  @override
  void initState() {
    super.initState();
    _folders = ref.read(machineScannerProvider).defaultSearchFolders();
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _addFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Look here');
    if (path == null) return;
    final canonical = resolveRepoPath(path);
    if (!_folders.contains(canonical)) setState(() => _folders.add(canonical));
  }

  Future<void> _runScan() async {
    setState(() {
      _step = _Step.scanning;
      _error = null;
    });
    try {
      final profiles = await ref.read(profileRepositoryProvider).getAll();
      final scan = await ref
          .read(machineScannerProvider)
          .scan(searchFolders: _folders, existingProfiles: profiles);
      if (!mounted) return;
      for (final d in _drafts) {
        d.dispose();
      }
      setState(() {
        _scan = scan;
        _drafts = [for (final s in scan.suggestions) _Draft(s)];
        _step = _Step.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "The scan didn't finish: $e";
        _step = _Step.intro;
      });
    }
  }

  String? _problem() {
    final kept = _drafts.where((d) => d.include).toList();
    if (kept.isEmpty) return 'Tick at least one profile, or press Skip.';
    final labels = <String>{};
    for (final d in kept) {
      if (d.existing) continue;
      if (d.label.text.trim().isEmpty) return 'Every profile needs a name.';
      if (!d.email.text.contains('@')) return '"${d.label.text}" needs an email address.';
      if (!labels.add(d.label.text.trim().toLowerCase())) {
        return 'Two profiles are called "${d.label.text.trim()}". Give one another name.';
      }
    }
    // A folder can only belong to one profile.
    final owner = <String, String>{};
    for (final d in kept) {
      for (final f in d.folders) {
        final other = owner[f.toLowerCase()];
        if (other != null) return '$f is ticked for both "$other" and "${d.label.text}".';
        owner[f.toLowerCase()] = d.label.text;
      }
    }
    return null;
  }

  Future<void> _apply() async {
    final problem = _problem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _step = _Step.applying;
      _error = null;
    });
    try {
      final result = await ref.read(setupActionsProvider).apply(
            [for (final d in _drafts) if (d.include) d.toChoice()],
            palette: profileColorPalette,
            trackProjects: _trackProjects,
          );
      if (!mounted) return;
      setState(() {
        _result = result;
        _step = _Step.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "Setting up didn't finish: $e";
        _step = _Step.review;
      });
    }
  }

  Future<void> _skip() async {
    await ref.read(setupActionsProvider).markSetupDone();
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _signIn(Profile profile) async {
    final flow = ref.read(gitHubDeviceFlowProvider);
    if (flow == null) return;
    final result = await showDialog<GitHubSignInResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GitHubSignInDialog(flow: flow, expectedLogin: profile.githubLogin),
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final message = await ref
          .read(doctorActionsProvider)
          .saveSignIn(profile.id, token: result.token, login: result.account.login);
      if (mounted) setState(() => _signedIn.add(profile.id));
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't save the sign-in: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Flexible(child: _body(context)),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: _buttons()),
            ],
          ),
        ),
      ),
    );
  }

  String get _title => switch (_step) {
        _Step.intro => 'Set up Gita',
        _Step.scanning => 'Looking at your projects…',
        _Step.review => 'Here is what Gita found',
        _Step.applying => 'Setting up…',
        _Step.done => 'All set',
      };

  List<Widget> _buttons() => switch (_step) {
        _Step.intro => [
            TextButton(onPressed: _skip, child: const Text('Skip for now')),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _folders.isEmpty ? null : _runScan,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Look for my accounts'),
            ),
          ],
        _Step.review => [
            TextButton(
              onPressed: () => setState(() => _step = _Step.intro),
              child: const Text('Back'),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: _skip, child: const Text('Skip')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _drafts.isEmpty ? null : _apply,
              child: const Text('Set these up'),
            ),
          ],
        _Step.done => [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Finish'),
            ),
          ],
        _ => [],
      };

  Widget _body(BuildContext context) => switch (_step) {
        _Step.intro => _intro(context),
        _Step.scanning || _Step.applying => const Center(
            child: Padding(padding: EdgeInsets.all(48), child: CircularProgressIndicator()),
          ),
        _Step.review => _review(context),
        _Step.done => _done(context),
      };

  Widget _intro(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gita can look at the projects on this computer, see which email '
            'each one commits with, and make a profile for each account '
            '(for example Work and Personal), with the right folders. '
            'Nothing changes until you press "Set these up".',
          ),
          const SizedBox(height: 16),
          Text('It will look in:', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          if (_folders.isEmpty)
            Text("None of the usual project folders are here. Add the folder "
                'where you keep your projects.', style: muted),
          for (final f in _folders)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined, size: 20),
              title: Text(f),
              trailing: IconButton(
                tooltip: "Don't look here",
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _folders.remove(f)),
              ),
            ),
          TextButton.icon(
            onPressed: _addFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('Add a folder'),
          ),
        ],
      ),
    );
  }

  Widget _review(BuildContext context) {
    final scan = _scan!;
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    if (_drafts.isEmpty) {
      return Text(
        'Gita looked at ${scan.repos.length} project(s) but found no email '
        'to make a profile from. Press Skip and add a profile yourself under '
        'Profiles.',
        style: muted,
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        Text(
          'Found ${scan.repos.length} project(s) and ${_drafts.length} '
          'account(s). Untick anything you don\'t want, and fix any names.',
          style: muted,
        ),
        const SizedBox(height: 12),
        for (final d in _drafts) _DraftCard(draft: d, keys: scan.sshKeys, onChanged: () => setState(() {})),
        if (scan.unknownRepos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${scan.unknownRepos.length} project(s) have no commits yet, so '
              "Gita couldn't tell their account. Add a rule for them under Rules "
              'if needed.',
              style: muted,
            ),
          ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _trackProjects,
          onChanged: (v) => setState(() => _trackProjects = v ?? true),
          title: const Text('Add these projects to the Dashboard with the safety check'),
          subtitle: const Text('Stops a commit or push with the wrong account before it happens.'),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    final r = _result!;
    final canSignIn = ref.watch(gitHubDeviceFlowProvider) != null;
    return ListView(
      shrinkWrap: true,
      children: [
        Text(
          [
            if (r.newProfiles > 0) '${r.newProfiles} new profile(s)',
            if (r.rules > 0) '${r.rules} folder rule(s)',
            if (r.sshKeys > 0) '${r.sshKeys} SSH key(s) linked',
            if (r.projects > 0) '${r.projects} project(s) on the Dashboard',
          ].join(', ').ifEmpty('Nothing new was needed.'),
        ),
        const SizedBox(height: 8),
        const Text(
          'Commits in those folders now use the right name and email. '
          'To push over HTTPS with the right GitHub account, sign each '
          'profile in once:',
        ),
        const SizedBox(height: 12),
        for (final profile in r.profiles)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(backgroundColor: Color(profile.colorArgb), radius: 10),
            title: Text(profile.label),
            subtitle: Text(profile.gitEmail),
            trailing: _signedIn.contains(profile.id)
                ? const Chip(avatar: Icon(Icons.check, size: 16), label: Text('Signed in'))
                : canSignIn
                    ? OutlinedButton(
                        onPressed: () => _signIn(profile),
                        child: const Text('Sign in with GitHub'),
                      )
                    : null,
          ),
        for (final p in r.projectProblems)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(p, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({required this.draft, required this.keys, required this.onChanged});

  final _Draft draft;
  final List<FoundSshKey> keys;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = draft.suggestion;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    final enabled = draft.include && !draft.existing;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: draft.include,
                  onChanged: (v) {
                    draft.include = v ?? false;
                    onChanged();
                  },
                ),
                Expanded(
                  child: Text(
                    '${s.email}  ·  ${s.repos.length} project(s)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (s.isGlobalDefault) Text('used everywhere else', style: muted),
                if (draft.existing) Text('  already a profile', style: muted),
              ],
            ),
            if (draft.include) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: draft.label,
                      enabled: enabled,
                      decoration: const InputDecoration(labelText: 'Profile name', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: draft.name,
                      enabled: enabled,
                      decoration: const InputDecoration(labelText: 'Your name in commits', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: draft.email,
                      enabled: enabled,
                      decoration: const InputDecoration(labelText: 'Email', isDense: true),
                    ),
                  ),
                ],
              ),
              if (keys.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<FoundSshKey?>(
                  initialValue: draft.sshKey,
                  isDense: true,
                  decoration: const InputDecoration(labelText: 'SSH key for git@github.com pushes'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None')),
                    for (final k in keys)
                      DropdownMenuItem(
                        value: k,
                        child: Text(k.comment == null ? k.fileName : '${k.fileName}  (${k.comment})'),
                      ),
                  ],
                  onChanged: draft.existing
                      ? null
                      : (k) {
                          draft.sshKey = k;
                          onChanged();
                        },
                ),
              ],
              const SizedBox(height: 8),
              if (s.folders.isEmpty)
                Text('No folders found for this account. You can add some under Rules later.',
                    style: muted)
              else ...[
                Text('Use this profile in:', style: muted),
                for (final f in s.folders)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: draft.folders.contains(f),
                    title: Text(f),
                    onChanged: (v) {
                      if (v ?? false) {
                        draft.folders.add(f);
                      } else {
                        draft.folders.remove(f);
                      }
                      onChanged();
                    },
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
