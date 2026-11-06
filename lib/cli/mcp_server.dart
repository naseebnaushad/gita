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
  says, in plain words, and how to fix it (often a tool below, or Gita).
- To download a project, use gita_clone instead of `git clone`, so it is
  downloaded and kept on the right account.
- gita_doctor finds setup problems; gita_profiles lists the accounts.

You can also set Gita up and fix it, when the user asks you to. Before a
tool that changes something, say in a sentence what it will change. A
typical setup:
  1. gita_scan to see the accounts the user's projects commit with, and
     confirm with the user which ones to set up.
  2. gita_setup (with "only" for the accounts they chose), or
     gita_profile_add for an account no project uses yet.
  3. gita_sign_in for each profile that isn't signed in: it gives a code;
     tell the user to enter it on the page it names. It finishes by
     itself; gita_profiles shows signedIn=true when it has.
  4. gita_company_import if their company gave them a Gita setup file.
  5. gita_doctor with fix=true, then tell the user about anything left.
Use gita_rule_add to make a folder, or a GitHub organization's projects,
use a profile.

Never change git's user.name/user.email or credentials yourself to work
around a problem Gita reports, and never ask the user for a password or
token: sign-ins go through gita_sign_in.''';

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
          'rules, company email mismatches) and how to fix each one. With '
          'fix=true it first fixes what needs no person: removes rules and SSH '
          'key links that point at something deleted, and makes a company '
          "organization's projects use the work profile.",
      {
        'fix': {
          'type': 'boolean',
          'description': 'Fix what can be fixed without the user (changes settings).',
        },
      },
      readOnly: false,
      idempotent: true,
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
    _tool(
      'gita_setup',
      'Set Gita up from the projects on this computer: scans like gita_scan, '
          'then adds a profile per account found, folder rules, SSH keys and '
          'the safety check in each project. Profiles that already exist are '
          'reused. Afterwards, sign in each profile listed in needSignIn.',
      {
        'folders': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Folders to look in (optional; default: the usual project folders).',
        },
        'only': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Emails of the accounts to set up (optional; default: all found).',
        },
        'track': {
          'type': 'boolean',
          'description': 'Add the safety check to each project (default true).',
        },
      },
      readOnly: false,
    ),
    _tool(
      'gita_profile_add',
      'Add a profile (an account to commit as) by hand, for example one no '
          'project on this computer uses yet.',
      {
        'name': {'type': 'string', 'description': 'Name to commit with, e.g. "Jane Doe".'},
        'email': {'type': 'string', 'description': 'Email to commit with.'},
        'label': {
          'type': 'string',
          'description': 'Short name for the profile, e.g. "Work" (optional).',
        },
        'githubLogin': {'type': 'string', 'description': 'GitHub account name (optional).'},
        'folders': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Absolute folders whose projects use this profile (optional).',
        },
      },
      required: ['name', 'email'],
      readOnly: false,
    ),
    _tool(
      'gita_profile_edit',
      "Change a profile's name, email, label or GitHub account.",
      {
        'profile': _profileProperty,
        'name': {'type': 'string', 'description': 'New name to commit with.'},
        'email': {'type': 'string', 'description': 'New email to commit with.'},
        'label': {'type': 'string', 'description': 'New short name for the profile.'},
        'githubLogin': {'type': 'string', 'description': 'GitHub account name.'},
      },
      required: ['profile'],
      readOnly: false,
      idempotent: true,
    ),
    _tool(
      'gita_rules',
      'List the rules: which folders, and which GitHub accounts or '
          "organizations' projects, use which profile.",
      {},
    ),
    _tool(
      'gita_rule_add',
      'Make projects use a profile: those in a folder (folder), or those '
          'from a GitHub account or organization wherever they are (owner). '
          'Give one of folder or owner. Replaces an existing rule for the same '
          'folder or owner.',
      {
        'profile': _profileProperty,
        'folder': {'type': 'string', 'description': 'Absolute folder path.'},
        'owner': {
          'type': 'string',
          'description': 'GitHub account or organization name, e.g. "acme".',
        },
        'host': {'type': 'string', 'description': 'Git host for owner (default github.com).'},
      },
      required: ['profile'],
      readOnly: false,
      idempotent: true,
    ),
    _tool(
      'gita_rule_remove',
      'Remove a rule, by its id (from gita_rules), its folder, or host/owner.',
      {
        'rule': {'type': 'string', 'description': 'Rule id, folder, or host/owner.'},
      },
      required: ['rule'],
      readOnly: false,
      destructive: true,
    ),
    _tool(
      'gita_company_import',
      "Read the company's Gita setup file and make every project from its "
          'GitHub organizations use the work profile, wherever it is.',
      {
        'file': {'type': 'string', 'description': 'Absolute path of the setup file.'},
        'profile': {
          'type': 'string',
          'description': 'Name or id of the work profile (optional; Gita picks '
              'the one with a company email).',
        },
      },
      required: ['file'],
      readOnly: false,
      idempotent: true,
    ),
    _tool(
      'gita_guard',
      "Add (install), take out (remove) or check (status) Gita's safety "
          'check in a project, which stops a commit or push with the wrong account.',
      {
        'action': {
          'type': 'string',
          'enum': ['install', 'remove', 'status'],
          'description': 'What to do.',
        },
        'path': _pathProperty,
      },
      required: ['action', 'path'],
      readOnly: false,
      idempotent: true,
    ),
    _tool(
      'gita_sign_in',
      'Sign a profile in to GitHub so HTTPS pushes use its account. Returns '
          'a code and a page right away: tell the user to open the page, sign '
          'in as that account and enter the code. Gita finishes by itself '
          '(gita_profiles shows signedIn=true). The token never passes through you.',
      {'profile': _profileProperty},
      required: ['profile'],
      readOnly: false,
      openWorld: true,
    ),
  ];

  static const _profileProperty = {
    'type': 'string',
    'description': 'Name (label) or id of the profile, from gita_profiles.',
  };

  static const _pathProperty = {
    'type': 'string',
    'description': 'Absolute path of the project folder (or any folder inside it).',
  };

  static Map<String, Object?> _tool(
    String name,
    String description,
    Map<String, Object?> properties, {
    List<String> required = const [],
    bool readOnly = true,
    bool destructive = false,
    bool idempotent = false,
    bool openWorld = false,
  }) =>
      {
        'name': name,
        'description': description,
        'inputSchema': {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        },
        'annotations': {
          'readOnlyHint': readOnly,
          if (!readOnly) 'destructiveHint': destructive,
          if (!readOnly) 'idempotentHint': idempotent,
          'openWorldHint': openWorld,
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

    List<String> list(String key) => [
          if (args[key] case final List<dynamic> items)
            for (final f in items)
              if (f is String && f.trim().isNotEmpty) f.trim(),
        ];
    List<String> option(String flag, String key) => [
          if (text(key) case final v?) ...['--$flag', v],
        ];

    final List<String> command = switch (name) {
      'gita_check' => ['check', ?text('path')],
      'gita_which' => ['which', ?text('path')],
      'gita_doctor' => ['doctor', if (args['fix'] == true) '--fix'],
      'gita_profiles' => ['profiles'],
      'gita_clone' => [
          'clone',
          text('address', required: true)!,
          ?text('folder'),
          if (text('profile') case final profile?) ...['--profile', profile],
        ],
      'gita_scan' => ['scan', '--json', '--', ...list('folders')],
      'gita_setup' => [
          'setup',
          for (final e in list('only')) ...['--only', e],
          if (args['track'] == false) '--no-track',
          '--json',
          '--',
          ...list('folders'),
        ],
      'gita_profile_add' => [
          'profile',
          '--name',
          text('name', required: true)!,
          '--email',
          text('email', required: true)!,
          ...option('label', 'label'),
          ...option('github-login', 'githubLogin'),
          for (final f in list('folders')) ...['--folder', f],
          'add',
        ],
      'gita_profile_edit' => [
          'profile',
          ...option('name', 'name'),
          ...option('email', 'email'),
          ...option('label', 'label'),
          ...option('github-login', 'githubLogin'),
          '--json',
          '--',
          'edit',
          text('profile', required: true)!,
        ],
      'gita_rules' => ['rule', 'list'],
      'gita_rule_add' => [
          'rule',
          '--profile',
          text('profile', required: true)!,
          ...option('folder', 'folder'),
          ...option('owner', 'owner'),
          ...option('host', 'host'),
          'add',
        ],
      'gita_rule_remove' => ['rule', '--json', '--', 'remove', text('rule', required: true)!],
      'gita_company_import' => [
          'company',
          ...option('profile', 'profile'),
          '--json',
          '--',
          'import',
          text('file', required: true)!,
        ],
      'gita_guard' => [
          'guard',
          '--json',
          '--',
          switch (text('action', required: true)) {
            final a? when const ['install', 'remove', 'status'].contains(a) => a,
            _ => throw _BadParams('"action" must be install, remove or status.'),
          },
          text('path', required: true)!,
        ],
      'gita_sign_in' => [
          'sign-in',
          '--profile',
          text('profile', required: true)!,
          '--no-wait',
        ],
      _ => throw _BadParams('Unknown tool: $name'),
    };

    // Commands that end in "--" (so paths and names can't be read as
    // options) already have --json before it.
    final result = await run(command.contains('--') ? command : [...command, '--json']);
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
