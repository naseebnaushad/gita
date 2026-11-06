import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/services/browser.dart';
import '../../core/services/github_device_flow.dart';

/// What a finished GitHub sign-in hands back to the profile editor.
class GitHubSignInResult {
  const GitHubSignInResult({required this.token, required this.account});

  final String token;
  final GitHubAccount account;
}

/// Walks the person through GitHub's device flow: shows a short code,
/// copies it and opens github.com/login/device, then waits for them to
/// approve. Pops with a [GitHubSignInResult], or null if they gave up.
class GitHubSignInDialog extends StatefulWidget {
  const GitHubSignInDialog({
    super.key,
    required this.flow,
    this.expectedLogin,
    this.openBrowser = openInBrowser,
  });

  final GitHubDeviceFlow flow;

  /// The account this profile was signed in with before, if any, so the
  /// dialog can say so when someone signs in as a different account.
  final String? expectedLogin;

  final Future<bool> Function(Uri) openBrowser;

  @override
  State<GitHubSignInDialog> createState() => _GitHubSignInDialogState();
}

enum _Step { starting, waiting, done, failed }

class _GitHubSignInDialogState extends State<GitHubSignInDialog> {
  _Step _step = _Step.starting;
  DeviceCode? _code;
  GitHubSignInResult? _result;
  String? _error;
  bool _openedBrowser = false;
  bool _browserFailed = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _step = _Step.starting;
      _error = null;
      _openedBrowser = false;
      _browserFailed = false;
    });
    try {
      final code = await widget.flow.start();
      if (_closed) return;
      setState(() {
        _code = code;
        _step = _Step.waiting;
      });
      final token = await widget.flow.waitForToken(code, isCancelled: () => _closed);
      final account = await widget.flow.fetchAccount(token);
      if (_closed) return;
      setState(() {
        _result = GitHubSignInResult(token: token, account: account);
        _step = _Step.done;
      });
    } on DeviceFlowException catch (e) {
      if (_closed) return;
      setState(() {
        _error = e.message;
        _step = _Step.failed;
      });
    }
  }

  Future<void> _copyAndOpen() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code.userCode));
    final opened = await widget.openBrowser(code.verificationUri);
    if (!mounted) return;
    setState(() {
      _openedBrowser = true;
      _browserFailed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sign in with GitHub'),
      content: SizedBox(width: 420, child: _body(context)),
      actions: [
        if (_step != _Step.done)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        if (_step == _Step.failed)
          FilledButton(onPressed: _run, child: const Text('Try again')),
        if (_step == _Step.done) ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not this account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _result),
            child: const Text('Use this account'),
          ),
        ],
      ],
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    switch (_step) {
      case _Step.starting:
        return const Row(
          children: [
            SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 14),
            Text('Asking GitHub for a sign-in code…'),
          ],
        );
      case _Step.failed:
        return Text(_error ?? 'Something went wrong.');
      case _Step.done:
        final account = _result!.account;
        final expected = widget.expectedLogin;
        final switched = expected != null &&
            expected.toLowerCase() != account.login.toLowerCase();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Signed in as @${account.login}',
                      style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Pushes from this profile\'s folders will use this GitHub '
                'account. If it\'s the wrong one, choose "Not this account", '
                'sign out of GitHub in your browser, and try again.'),
            if (switched) ...[
              const SizedBox(height: 12),
              Text(
                'This profile used @$expected before.',
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
        );
      case _Step.waiting:
        final code = _code!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Make sure your browser is signed in to the GitHub '
                'account this profile should push as.'),
            const SizedBox(height: 8),
            const Text('2. Copy this code and paste it on the GitHub page:'),
            const SizedBox(height: 14),
            Center(
              child: SelectableText(
                code.userCode,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: FilledButton.icon(
                onPressed: _copyAndOpen,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(_openedBrowser ? 'Copy code and open GitHub again' : 'Copy code and open GitHub'),
              ),
            ),
            if (_browserFailed) ...[
              const SizedBox(height: 10),
              SelectableText('The code is copied. Open ${code.verificationUri} '
                  'in your browser and paste it there.'),
            ],
            const SizedBox(height: 14),
            const Text('3. Press Authorize on GitHub. This window carries on by itself.'),
            const SizedBox(height: 14),
            Row(
              children: [
                const SizedBox.square(
                    dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Waiting for GitHub…',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        );
    }
  }
}
