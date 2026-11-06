import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/ssh_key.dart';
import '../../core/services/browser.dart';
import '../../core/services/github_ssh_keys.dart';
import '../../core/services/ssh_key_service.dart';

/// Sets up SSH for one profile, doing as much as it can by itself:
/// creates the key (unless [existing] is given), adds it to the GitHub
/// account when the profile is signed in, and checks which account GitHub
/// sees. When it can't add the key itself it shows the few steps to do it
/// by hand. Pops with the key, or null if no key was made.
class SshSetupDialog extends StatefulWidget {
  const SshSetupDialog({
    super.key,
    required this.sshKeys,
    required this.gitHub,
    required this.profileLabel,
    required this.email,
    required this.onKeyCreated,
    this.existing,
    this.token,
    this.expectedLogin,
    this.openBrowser = openInBrowser,
  });

  final SshKeyService sshKeys;
  final GitHubSshKeys gitHub;
  final String profileLabel;
  final String email;

  /// Saves a newly made key, so it isn't lost if the profile editor is
  /// cancelled afterwards.
  final Future<void> Function(SshKey) onKeyCreated;

  final SshKey? existing;

  /// The profile's GitHub token, used to add the key to the account.
  final String? token;

  /// The GitHub account the profile is signed in as, if known.
  final String? expectedLogin;

  final Future<bool> Function(Uri) openBrowser;

  @override
  State<SshSetupDialog> createState() => _SshSetupDialogState();
}

class _SshSetupDialogState extends State<SshSetupDialog> {
  SshKey? _key;
  String? _publicKey;
  String _status = '';
  bool _busy = true;
  String? _error;
  AddSshKeyResult? _added;
  SshCheckResult? _check;
  bool _copied = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _key = widget.existing;
    _run();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  void _update(VoidCallback change) {
    if (!_closed) setState(change);
  }

  Future<void> _run() async {
    try {
      var key = _key;
      if (key == null) {
        _update(() => _status = 'Creating a key for this profile…');
        key = await widget.sshKeys.generate(
          profileLabel: widget.profileLabel,
          email: widget.email,
        );
        await widget.onKeyCreated(key);
        _update(() => _key = key);
      }
      final publicKey = await widget.sshKeys.readPublicKey(key);
      _update(() => _publicKey = publicKey);

      // So the first push doesn't stop to ask whether to trust GitHub.
      await widget.sshKeys.trustGitHub(widget.gitHub.hostKeys);

      final token = widget.token?.trim() ?? '';
      if (token.isNotEmpty) {
        _update(() => _status = 'Adding the key to your GitHub account…');
        final added = await widget.gitHub.add(
          token: token,
          title: 'Gita: ${widget.profileLabel} (${Platform.localHostname})',
          publicKey: publicKey,
        );
        _update(() => _added = added);
      }
      await _checkNow();
    } on SshKeyException catch (e) {
      _update(() {
        _error = e.message;
        _busy = false;
      });
    } on FileSystemException catch (e) {
      _update(() {
        _error = "Couldn't read the key: ${e.message} (${e.path})";
        _busy = false;
      });
    }
  }

  Future<void> _checkNow() async {
    final key = _key;
    if (key == null) return;
    _update(() {
      _busy = true;
      _status = 'Checking which GitHub account the key signs in as…';
    });
    final check = await widget.sshKeys.check(key);
    _update(() {
      _check = check;
      _busy = false;
    });
  }

  bool get _wrongAccount {
    final login = _check?.login;
    final expected = widget.expectedLogin;
    return login != null && expected != null && login.toLowerCase() != expected.toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget body;
    if (_error != null) {
      body = _line(Icons.error_outline, scheme.error, _error!);
    } else if (_busy) {
      body = Row(children: [
        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Expanded(child: Text(_status)),
      ]);
    } else if (_check?.works == true && !_wrongAccount) {
      body = _line(Icons.check_circle, scheme.secondary,
          'SSH works. GitHub signs this key in as @${_check!.login}. Pushes to '
          'git@github.com remotes in this profile\'s folders now use it.');
    } else {
      body = _manualSteps(context);
    }

    return AlertDialog(
      title: const Text('SSH for this profile'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: body)),
      actions: [
        if (!_busy && _key != null && (_check?.works != true || _wrongAccount))
          TextButton(onPressed: _checkNow, child: const Text('Check again')),
        FilledButton(
          onPressed: _busy && _key == null ? null : () => Navigator.pop(context, _key),
          child: Text(_check?.works == true && !_wrongAccount ? 'Done' : 'Close'),
        ),
      ],
    );
  }

  Widget _manualSteps(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final expected = widget.expectedLogin;
    final account = expected == null ? 'the GitHub account for this profile' : '@$expected';

    final String why;
    if (_wrongAccount) {
      why = 'This key signs in as @${_check!.login}, not @$expected. On GitHub, '
          "remove it from @${_check!.login}'s SSH keys, then add it to @$expected:";
    } else {
      why = switch (_added?.outcome) {
        AddSshKeyOutcome.needsPermission =>
          "Gita isn't allowed to add keys with this profile's sign-in yet. "
              'Press "Sign in with GitHub" in the profile again to let it, or '
              'add the key yourself:',
        AddSshKeyOutcome.badToken =>
          "GitHub no longer accepts this profile's sign-in. Sign in again, or "
              'add the key yourself:',
        AddSshKeyOutcome.network =>
          "Couldn't reach GitHub to add the key. Check the internet "
              'connection, or add the key yourself:',
        AddSshKeyOutcome.added || AddSshKeyOutcome.alreadyAdded =>
          'The key is on GitHub, but signing in with it didn\'t work: '
              '${_check?.message ?? ''}',
        AddSshKeyOutcome.failed =>
          'GitHub didn\'t take the key${_added?.detail == null ? '' : ' (${_added!.detail})'}. '
              'Add it yourself:',
        null => 'Add this key to $account on GitHub:',
      };
    }

    final onGitHub = _added?.onGitHub == true && !_wrongAccount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(why),
        if (!onGitHub) ...[
          const SizedBox(height: 14),
          Text('1. Copy the key', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _publicKey ?? '',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _publicKey == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: _publicKey!));
                      _update(() => _copied = true);
                    },
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 18),
              label: Text(_copied ? 'Copied' : 'Copy key'),
            ),
          ),
          const SizedBox(height: 14),
          Text('2. Add it on GitHub', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text('Check that GitHub shows $account at the top right. Paste the '
              'key into "Key", give it any title, and press "Add SSH key".'),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => widget.openBrowser(GitHubSshKeys.newKeyPage),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Open GitHub'),
            ),
          ),
          const SizedBox(height: 14),
          Text('3. Come back and press "Check again"', style: theme.textTheme.titleSmall),
        ],
        if (_check?.works != true && _check?.message != null && !onGitHub) ...[
          const SizedBox(height: 10),
          Text('Last check: ${_check!.message}',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Widget _line(IconData icon, Color color, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      );
}
