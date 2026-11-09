import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/models/profile.dart';
import '../../core/providers.dart';
import '../../core/services/clone_service.dart';
import '../../core/services/path_resolver.dart';
import '../profiles/github_sign_in_dialog.dart';
import '../profiles/profiles_screen.dart' show showProfileEditor;

/// Opens the clone dialog. Returns the outcome when something was cloned.
Future<CloneOutcome?> showCloneDialog(BuildContext context) => showDialog<CloneOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const CloneDialog(),
    );

/// Downloads a project with the right account, in three plain fields:
/// the address, the profile, and where to put it.
class CloneDialog extends ConsumerStatefulWidget {
  const CloneDialog({super.key});

  @override
  ConsumerState<CloneDialog> createState() => _CloneDialogState();
}

class _CloneDialogState extends ConsumerState<CloneDialog> {
  final _url = TextEditingController();
  Profile? _profile;
  bool _profilePicked = false;
  String? _parentFolder;
  bool _signedIn = true;
  bool _busy = false;
  String? _progress;
  String? _error;

  /// For a failed clone: what can fix it, and git's own words.
  CloneProblem? _problem;
  String? _gitDetail;

  /// Said after a fix worked ("Signed in as @x. Press Clone to try again.").
  String? _notice;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  String get _name => CloneService.repoNameFromUrl(_url.text) ?? '';

  String? get _destination =>
      _parentFolder == null || _name.isEmpty ? null : p.posix.join(_parentFolder!, _name);

  Future<void> _urlChanged(List<Profile> profiles) async {
    if (!_profilePicked) {
      final rules = await ref.read(repoRulesProvider.future);
      final suggested = CloneService.suggestProfile(
        _url.text,
        profiles,
        rules: rules,
      );
      if (suggested != null) await _setProfile(suggested, picked: false);
    }
    setState(_clearProblem);
  }

  void _clearProblem() {
    _error = null;
    _problem = null;
    _gitDetail = null;
    _notice = null;
  }

  Future<void> _setProfile(Profile profile, {required bool picked}) async {
    final rules = await ref.read(repoRulesProvider.future);
    final signedIn = await ref.read(secureTokenServiceProvider).hasToken(profile.id);
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _profilePicked = _profilePicked || picked;
      _parentFolder = ref.read(cloneServiceProvider).parentFolderFor(profile, rules);
      _signedIn = signedIn;
    });
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(
      initialDirectory: _parentFolder,
      confirmButtonText: 'Put it here',
    );
    if (path != null) setState(() => _parentFolder = resolveRepoPath(path));
  }

  String? _hint() {
    final profile = _profile;
    if (profile == null || _url.text.trim().isEmpty) return null;
    if (CloneService.isSshUrl(_url.text) && profile.sshKeyId == null) {
      return '${profile.label} has no SSH key yet. Use the HTTPS address, '
          'or press "Set up SSH" in the profile first.';
    }
    if (!CloneService.isSshUrl(_url.text) && !_signedIn) {
      return '${profile.label} is not signed in to GitHub, so only public '
          'projects will download. Sign it in under Profiles for private ones.';
    }
    return null;
  }

  Future<void> _clone() async {
    final profile = _profile;
    final dest = _destination;
    if (!CloneService.looksLikeGitUrl(_url.text)) {
      setState(() => _error = "That doesn't look like a project address. Copy it "
          'from the green Code button on GitHub, e.g. https://github.com/acme/api.git');
      return;
    }
    if (profile == null) {
      setState(() => _error = 'Pick which account this project belongs to.');
      return;
    }
    if (dest == null) {
      setState(() => _error = 'Pick a folder to put it in.');
      return;
    }
    setState(() {
      _busy = true;
      _clearProblem();
      _progress = 'Starting…';
    });
    final outcome = await ref.read(cloneActionsProvider).clone(
          url: _url.text,
          destination: dest,
          profile: profile,
          onProgress: (line) {
            if (mounted) setState(() => _progress = line);
          },
        );
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(outcome);
    } else {
      setState(() {
        _busy = false;
        _progress = null;
        _error = outcome.message;
        _problem = outcome.problem;
        _gitDetail = outcome.gitDetail;
      });
    }
  }

  /// Runs the fix for [_problem], then says what to do next.
  Future<void> _fix() async {
    final profile = _profile;
    final problem = _problem;
    if (profile == null || problem == null) return;
    setState(() => _busy = true);
    String? notice;
    try {
      switch (problem) {
        case CloneProblem.signIn:
          notice = await _signIn(profile);
        case CloneProblem.helper:
          notice = await ref.read(doctorActionsProvider).installCli();
        case CloneProblem.sshKey:
          await showProfileEditor(context, profile);
      }
    } catch (e) {
      notice = "That didn't work: ${e is StateError ? e.message : e}";
    }
    if (!mounted) return;
    // The profile may have changed (new sign-in, SSH key): read it again.
    final profiles = await ref.read(profilesProvider.future);
    final fresh = profiles.where((x) => x.id == profile.id).firstOrNull ?? profile;
    final signedIn = await ref.read(secureTokenServiceProvider).hasToken(fresh.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _profile = fresh;
      _signedIn = signedIn;
      if (notice != null) {
        _clearProblem();
        _notice = '$notice Press Clone to try again.';
      }
    });
  }

  /// GitHub sign-in for [profile], saved like Doctor does. Without Gita's
  /// GitHub sign-in app, opens the profile so a token can be pasted.
  /// Returns what to tell the person, or null if they gave up.
  Future<String?> _signIn(Profile profile) async {
    final flow = ref.read(gitHubDeviceFlowProvider);
    if (flow == null) {
      await showProfileEditor(context, profile);
      final signedIn = await ref.read(secureTokenServiceProvider).hasToken(profile.id);
      return signedIn ? '${profile.label} is signed in.' : null;
    }
    final result = await showDialog<GitHubSignInResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GitHubSignInDialog(flow: flow, expectedLogin: profile.githubLogin),
    );
    if (result == null) return null;
    await ref
        .read(doctorActionsProvider)
        .saveSignIn(profile.id, token: result.token, login: result.account.login);
    return 'Signed in as @${result.account.login}.';
  }

  String get _fixLabel => switch (_problem) {
        CloneProblem.signIn => 'Sign in with GitHub',
        CloneProblem.helper => 'Reinstall the gita command',
        CloneProblem.sshKey => 'Open the profile',
        null => '',
      };

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final hint = _hint();
    return AlertDialog(
      title: const Text('Clone a project'),
      content: SizedBox(
        width: 560,
        child: profiles.isEmpty
            ? const Text('Add a profile first (or press "Scan this computer" '
                'under Profiles), so Gita knows which account to use.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _url,
                    enabled: !_busy,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Project address',
                      hintText: 'https://github.com/acme/api.git',
                      helperText: "On the project's GitHub page, under the green Code button.",
                    ),
                    onChanged: (_) => _urlChanged(profiles),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _profile?.id,
                    key: ValueKey(_profile?.id),
                    decoration: const InputDecoration(labelText: 'Account (profile)'),
                    items: [
                      for (final pr in profiles)
                        DropdownMenuItem(
                          value: pr.id,
                          child: Text('${pr.label}  <${pr.gitEmail}>'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) {
                            final chosen = profiles.where((x) => x.id == id).firstOrNull;
                            if (chosen != null) _setProfile(chosen, picked: true);
                          },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Put it in', style: Theme.of(context).textTheme.labelMedium),
                            const SizedBox(height: 2),
                            Text(_destination ?? _parentFolder ?? 'Pick an account first', style: muted),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _pickFolder,
                        child: const Text('Change'),
                      ),
                    ],
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: 12),
                    Text(hint, style: muted),
                  ],
                  if (_progress != null) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    Text(_progress!, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    if (_gitDetail != null) ...[
                      const SizedBox(height: 4),
                      SelectableText('git said: $_gitDetail',
                          style: muted.copyWith(fontSize: 12)),
                    ],
                    if (_problem != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.tonalIcon(
                          onPressed: _busy ? null : _fix,
                          icon: Icon(
                            _problem == CloneProblem.helper ? Icons.build_outlined : Icons.login,
                            size: 18,
                          ),
                          label: Text(_fixLabel),
                        ),
                      ),
                    ],
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 12),
                    Text(_notice!, style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (profiles.isNotEmpty)
          FilledButton(
            onPressed: _busy ? null : _clone,
            child: const Text('Clone'),
          ),
      ],
    );
  }
}
