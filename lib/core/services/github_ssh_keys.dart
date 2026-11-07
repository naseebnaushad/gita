import 'dart:convert';

import 'github_device_flow.dart';

enum AddSshKeyOutcome {
  /// GitHub now has the key.
  added,

  /// GitHub already had this key (on this account or another one; a
  /// check over SSH tells which).
  alreadyAdded,

  /// The token isn't allowed to add keys: it was made before Gita asked
  /// for that permission, or it is a pasted token without it.
  needsPermission,

  /// GitHub no longer accepts the token.
  badToken,

  /// No answer from GitHub.
  network,

  /// Anything else; the result's detail says what GitHub sent.
  failed,
}

class AddSshKeyResult {
  const AddSshKeyResult(this.outcome, {this.detail});

  final AddSshKeyOutcome outcome;
  final String? detail;

  bool get onGitHub =>
      outcome == AddSshKeyOutcome.added || outcome == AddSshKeyOutcome.alreadyAdded;
}

/// The two SSH-related GitHub API calls: adding a public key to the
/// signed-in account, and reading GitHub's own SSH host keys.
class GitHubSshKeys {
  GitHubSshKeys({GitHubHttp? http}) : http = http ?? IoGitHubHttp();

  final GitHubHttp http;

  static final _keysUri = Uri.parse('https://api.github.com/user/keys');
  static final _metaUri = Uri.parse('https://api.github.com/meta');

  /// Where people add a key by hand.
  static final newKeyPage = Uri.parse('https://github.com/settings/ssh/new');

  Future<AddSshKeyResult> add({
    required String token,
    required String title,
    required String publicKey,
  }) async {
    final GitHubResponse response;
    try {
      response = await http.postJson(_keysUri, token, {'title': title, 'key': publicKey});
    } on Exception {
      return const AddSshKeyResult(AddSshKeyOutcome.network);
    }
    switch (response.statusCode) {
      case 201:
        return const AddSshKeyResult(AddSshKeyOutcome.added);
      case 401:
        return const AddSshKeyResult(AddSshKeyOutcome.badToken);
      case 403:
      case 404:
        // GitHub answers 404 rather than 403 when a token lacks the scope.
        return const AddSshKeyResult(AddSshKeyOutcome.needsPermission);
      case 422:
        if (response.body.contains('already in use')) {
          return const AddSshKeyResult(AddSshKeyOutcome.alreadyAdded);
        }
    }
    return AddSshKeyResult(AddSshKeyOutcome.failed, detail: _message(response.body));
  }

  /// GitHub's SSH host keys, e.g. `ssh-ed25519 AAAA...`. Empty if GitHub
  /// couldn't be reached.
  Future<List<String>> hostKeys() async {
    try {
      final response = await http.get(_metaUri, '');
      if (response.statusCode != 200) return const [];
      final json = jsonDecode(response.body);
      final keys = json is Map<String, dynamic> ? json['ssh_keys'] : null;
      if (keys is! List) return const [];
      return keys.whereType<String>().where((k) => k.startsWith('ssh-') || k.startsWith('ecdsa-')).toList();
    } on Exception {
      return const [];
    }
  }

  static String? _message(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) {
        final errors = json['errors'];
        if (errors is List && errors.isNotEmpty && errors.first is Map) {
          return (errors.first as Map)['message']?.toString() ?? json['message']?.toString();
        }
        return json['message']?.toString();
      }
    } on FormatException {
      // Not JSON.
    }
    return null;
  }
}
