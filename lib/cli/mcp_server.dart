import 'dart:async';
import 'dart:convert';

/// Runs one `gita` command line (always with `--json`) and returns its
/// exit code, standard output and error output.
typedef GitaRunner = Future<({int exitCode, String out, String err})> Function(
  List<String> args,
);

/// `gita mcp`: an MCP (Model Context Protocol) server on stdin/stdout, so
/// AI coding agents such as Claude Code can ask Gita which account a
/// project should use before they commit, push or clone.
///
/// Messages are JSON-RPC 2.0, one per line. Every tool runs the matching
/// `gita ... --json` command, so agents get exactly what scripts get.
class GitaMcpServer {
  GitaMcpServer({required this.run, required this.output, this.version = '0.0.0'});

  final GitaRunner run;
  final StringSink output;
  final String version;

  static const protocolVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

  static const instructions = '''
Gita keeps each git project on the right GitHub account (for example a
personal and a work account on one computer).

- Before you commit or push in a project, call gita_check with its folder.
  If it reports a problem, don't commit or push: tell the user what it
  says, in plain words, and how to fix it (often: open Gita, or run the
  suggested command).
- To download a project, use gita_clone instead of `git clone`, so it is
  downloaded and kept on the right account.
- gita_doctor finds setup problems; gita_profiles lists the accounts.
Never change git's user.name/user.email or credentials yourself to work
around a problem Gita reports.''';

  static final List<Map<String, Object?>> tools = [
    _tool(
      'gita_check',
      'Check that a git project will commit and push with the right account. '
          'Call before committing or pushing. ok=false means a commit or push '
          'would use the wrong account; the result says what to do.',
      {'path': _pathProperty},
    ),
    _tool(
      'gita_which',
      'Which account (profile) a project should use, which email it commits '
          'with right now, and which rule decided it.',
      {'path': _pathProperty},
    ),
    _tool(
      'gita_doctor',
      'Look for setup problems (missing SSH keys, GitHub sign-ins, broken '
          'rules, company email mismatches) and how to fix each one.',
      {},
    ),
    _tool(
      'gita_profiles',
      'List the profiles (accounts): name, email, GitHub account, sign-in, '
          'SSH key and the folders or organizations that use each one.',
      {},
    ),
    _tool(
      'gita_clone',
      'Download a project with the right account (its GitHub sign-in or SSH '
          'key) and keep it on that account. Use instead of git clone.',
      {
        'address': {
          'type': 'string',
          'description': 'The project address, e.g. https://github.com/acme/api.git '
              'or git@github.com:acme/api.git',
        },
        'folder': {
          'type': 'string',
          'description': 'Where to put it (optional; Gita picks the account\'s folder).',
        },
        'profile': {
          'type': 'string',
          'description': 'Name of the profile to use (optional; Gita works it out '
              'from the address when it can).',
        },
      },
      required: ['address'],
    ),
    _tool(
      'gita_scan',
      'Look through projects on this computer and suggest profiles and '
          'folder rules. Only looks; changes nothing.',
      {
        'folders': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Folders to look in (optional; default: the usual project folders).',
        },
      },
    ),
  ];

  static const _pathProperty = {
    'type': 'string',
    'description': 'Absolute path of the project folder (or any folder inside it).',
  };

  static Map<String, Object?> _tool(
    String name,
    String description,
    Map<String, Object?> properties, {
    List<String> required = const [],
  }) =>
      {
        'name': name,
        'description': description,
        'inputSchema': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
      };

  /// Serves requests from [lines] until it closes. Requests are handled
  /// one at a time, so replies come back in order.
  Future<void> serve(Stream<String> lines) async {
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final reply = await handleLine(line);
      if (reply != null) output.writeln(jsonEncode(reply));
    }
  }

  /// The reply to one message, or null for notifications.
  Future<Map<String, Object?>?> handleLine(String line) async {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return _error(null, -32700, 'Parse error');
    }
    if (message is! Map<String, dynamic>) {
      return _error(null, -32600, 'Invalid request');
    }
    final id = message['id'];
    final method = message['method'];
    final isNotification = !message.containsKey('id');
    if (method is! String) {
      return isNotification ? null : _error(id, -32600, 'Invalid request');
    }
    final params = message['params'] is Map<String, dynamic>
        ? message['params'] as Map<String, dynamic>
        : const <String, dynamic>{};

    try {
      final Object? result = switch (method) {
        'initialize' => _initialize(params),
        'ping' => const <String, Object?>{},
        'tools/list' => {'tools': tools},
        'tools/call' => await _call(params),
        _ => null,
      };
      if (isNotification) return null;
      if (result == null) return _error(id, -32601, 'Method not found: $method');
      return {'jsonrpc': '2.0', 'id': id, 'result': result};
    } on _BadParams catch (e) {
      return isNotification ? null : _error(id, -32602, e.message);
    }
  }

  Map<String, Object?> _initialize(Map<String, dynamic> params) {
    final asked = params['protocolVersion'];
    return {
      'protocolVersion': protocolVersions.contains(asked) ? asked : protocolVersions.first,
      'capabilities': {'tools': <String, Object?>{}},
      'serverInfo': {'name': 'gita', 'version': version},
      'instructions': instructions,
    };
  }

  Future<Map<String, Object?>> _call(Map<String, dynamic> params) async {
    final name = params['name'];
    final args = params['arguments'] is Map<String, dynamic>
        ? params['arguments'] as Map<String, dynamic>
        : const <String, dynamic>{};
    String? text(String key, {bool required = false}) {
      final v = args[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (required) throw _BadParams('"$key" is required.');
      return null;
    }

    final List<String> command = switch (name) {
      'gita_check' => ['check', ?text('path')],
      'gita_which' => ['which', ?text('path')],
      'gita_doctor' => ['doctor'],
      'gita_profiles' => ['profiles'],
      'gita_clone' => [
          'clone',
          text('address', required: true)!,
          ?text('folder'),
          if (text('profile') case final profile?) ...['--profile', profile],
        ],
      'gita_scan' => [
          'scan',
          if (args['folders'] case final List<dynamic> folders)
            for (final f in folders)
              if (f is String && f.trim().isNotEmpty) f.trim(),
        ],
      _ => throw _BadParams('Unknown tool: $name'),
    };

    final result = await run([...command, '--json']);
    final body = result.out.trim().isNotEmpty ? result.out.trim() : result.err.trim();
    return {
      'content': [
        {'type': 'text', 'text': body.isEmpty ? '(no output, exit code ${result.exitCode})' : body},
      ],
      // Exit code 1 is a finding (wrong account, problems found), which is
      // a normal answer. Exit code 2 means the command couldn't run.
      'isError': result.exitCode >= 2,
    };
  }

  Map<String, Object?> _error(Object? id, int code, String message) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };
}

class _BadParams implements Exception {
  _BadParams(this.message);
  final String message;
}
