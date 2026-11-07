import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/cli/mcp_server.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:path/path.dart' as p;

/// `gita mcp`: MCP over stdin/stdout, driven through the real CLI against a
/// temp home.
void main() {
  late Directory home;
  late PlatformPaths paths;
  late GitService git;
  late StringBuffer out;
  late StringBuffer err;
  late List<List<String>> processCalls;
  late ProcessResult Function(String exe, List<String> args) fakeProcess;

  GitaCli cli({List<String> lines = const []}) => GitaCli(
        out: out,
        err: err,
        paths: paths,
        gitService: git,
        tokenStore: TokenStore(keychain: InMemoryKeychainStore()),
        input: Stream.value(utf8.encode(lines.map((l) => '$l\n').join())),
        runProcess: (exe, args) async {
          processCalls.add([exe, ...args]);
          return fakeProcess(exe, args);
        },
      );

  /// Sends [messages] (one JSON-RPC message each) and returns the replies.
  Future<List<Map<String, dynamic>>> talk(List<Object> messages) async {
    final code = await cli(
      lines: [for (final m in messages) m is String ? m : jsonEncode(m)],
    ).run(['mcp']);
    expect(code, 0, reason: '$err');
    return [
      for (final line in const LineSplitter().convert(out.toString()))
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  Map<String, Object> call(int id, String tool, [Map<String, Object> args = const {}]) => {
        'jsonrpc': '2.0',
        'id': id,
        'method': 'tools/call',
        'params': {'name': tool, 'arguments': args},
      };

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_mcp_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    git = GitService(environmentOverride: {
      'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
      'GIT_CONFIG_SYSTEM': p.join(home.path, 'gitconfig_system'),
    });
    File(paths.gitConfigPath).writeAsStringSync('[user]\n  name = Me\n  email = me@gmail.com\n');
    out = StringBuffer();
    err = StringBuffer();
    processCalls = [];
    fakeProcess = (_, _) => ProcessResult(0, 0, '', '');
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  test('initialize, notifications, ping and tools/list', () async {
    final replies = await talk([
      {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-03-26',
          'capabilities': {},
          'clientInfo': {'name': 'test', 'version': '1'},
        },
      },
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'id': 2, 'method': 'ping'},
      {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'},
    ]);

    expect(replies, hasLength(3), reason: 'notifications get no reply');
    final init = replies[0]['result'] as Map<String, dynamic>;
    expect(replies[0]['id'], 1);
    expect(init['protocolVersion'], '2025-03-26');
    expect(init['serverInfo'], {'name': 'gita', 'version': GitaCli.version});
    expect(init['capabilities'], {'tools': {}});
    expect(init['instructions'], contains('gita_check'));

    expect(replies[1], {'jsonrpc': '2.0', 'id': 2, 'result': {}});

    final tools = (replies[2]['result']['tools'] as List).cast<Map<String, dynamic>>();
    expect(tools.map((t) => t['name']), [
      'gita_check',
      'gita_which',
      'gita_doctor',
      'gita_profiles',
      'gita_clone',
      'gita_scan',
      'gita_setup',
      'gita_profile_add',
      'gita_profile_edit',
      'gita_rules',
      'gita_rule_add',
      'gita_rule_remove',
      'gita_company_import',
      'gita_guard',
      'gita_sign_in',
    ]);
    for (final t in tools) {
      expect(t['description'], isNotEmpty);
      expect(t['inputSchema']['type'], 'object');
      expect(t['annotations']['readOnlyHint'], isA<bool>());
    }
    bool readOnly(String name) => tools.firstWhere((t) => t['name'] == name)['annotations']['readOnlyHint'] as bool;
    for (final name in ['gita_check', 'gita_which', 'gita_profiles', 'gita_scan', 'gita_rules']) {
      expect(readOnly(name), isTrue, reason: name);
    }
    // Every other tool changes something, so none of them may claim to be
    // read-only (a client may run read-only tools without asking).
    for (final t in tools) {
      final name = t['name'] as String;
      if (['gita_check', 'gita_which', 'gita_profiles', 'gita_scan', 'gita_rules'].contains(name)) continue;
      expect(readOnly(name), isFalse, reason: name);
    }
    expect(tools.firstWhere((t) => t['name'] == 'gita_clone')['annotations']['openWorldHint'], isTrue);
    expect(tools.firstWhere((t) => t['name'] == 'gita_rule_remove')['annotations']['destructiveHint'], isTrue);
    expect(init['instructions'], contains('gita_setup'));
    expect(tools.firstWhere((t) => t['name'] == 'gita_clone')['inputSchema']['required'], ['address']);
  });

  test('an unknown protocol version gets the newest one', () async {
    final replies = await talk([
      {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '1999-01-01'}},
    ]);
    expect(replies.single['result']['protocolVersion'], GitaMcpServer.protocolVersions.first);
  });

  test('tools run the matching gita command and return its JSON', () async {
    final project = Directory(p.join(home.path, 'Projects', 'acme', 'api'))..createSync(recursive: true);
    for (final args in [
      ['init', '-q'],
      ['config', 'user.email', 'dev@acme.com'],
      ['config', 'user.name', 'Dev'],
    ]) {
      expect((await git.raw(args, workingDir: project.path)).exitCode, 0);
    }

    final replies = await talk([
      call(1, 'gita_profiles'),
      call(2, 'gita_scan', {
        'folders': [p.join(home.path, 'Projects')],
      }),
      call(3, 'gita_which', {'path': project.path}),
      call(4, 'gita_check', {'path': project.path}),
      call(5, 'gita_doctor'),
    ]);
    expect(replies.map((r) => r['id']), [1, 2, 3, 4, 5], reason: 'replies come back in order');

    Map<String, dynamic> body(int i) {
      final result = replies[i]['result'] as Map<String, dynamic>;
      final content = (result['content'] as List).single as Map<String, dynamic>;
      expect(content['type'], 'text');
      return {'isError': result['isError'], 'json': jsonDecode(content['text'] as String)};
    }

    expect(body(0)['isError'], isFalse);
    expect(body(0)['json'], {'ok': true, 'profiles': []});

    final scan = body(1);
    expect(scan['isError'], isFalse);
    expect(jsonEncode(scan['json']), contains('dev@acme.com'));

    final which = body(2);
    expect(which['isError'], isFalse);
    expect(jsonEncode(which['json']), contains('dev@acme.com'));

    expect(body(3)['isError'], isFalse, reason: 'exit 1 is an answer, not an error');
    expect(body(4)['isError'], isFalse);
  });

  test('a folder that is not a project is a tool error, not a crash', () async {
    final notAProject = Directory(p.join(home.path, 'empty'))..createSync();
    final replies = await talk([call(1, 'gita_check', {'path': notAProject.path})]);
    final result = replies.single['result'] as Map<String, dynamic>;
    expect(result['isError'], isTrue);
    expect((result['content'] as List).single['text'], isNotEmpty);
  });

  test('bad requests get JSON-RPC errors and the server keeps going', () async {
    final replies = await talk([
      'this is not json',
      {'jsonrpc': '2.0', 'id': 1, 'method': 'resources/list'},
      call(2, 'gita_delete_everything'),
      call(3, 'gita_clone'),
      '[1, 2]',
      {'jsonrpc': '2.0', 'id': 4, 'method': 'ping'},
    ]);
    expect(replies, hasLength(6));
    expect(replies[0]['error']['code'], -32700);
    expect(replies[0]['id'], isNull);
    expect(replies[1]['error']['code'], -32601);
    expect(replies[2]['error']['code'], -32602);
    expect(replies[3]['error']['code'], -32602);
    expect(replies[3]['error']['message'], contains('address'));
    expect(replies[4]['error']['code'], -32600);
    expect(replies[5]['result'], {});
  });

  test('gita_clone passes the address, folder and profile through', () async {
    final seen = <List<String>>[];
    final server = GitaMcpServer(
      output: StringBuffer(),
      run: (args) async {
        seen.add(args);
        return (exitCode: 0, out: '{"ok":true}', err: '');
      },
    );
    final reply = await server.handleLine(jsonEncode(call(1, 'gita_clone', {
      'address': ' https://github.com/acme/api.git ',
      'folder': '/work/api',
      'profile': 'Work',
    })));
    expect(seen.single, ['clone', 'https://github.com/acme/api.git', '/work/api', '--profile', 'Work', '--json']);
    expect((reply!['result'] as Map)['isError'], isFalse);

    seen.clear();
    await server.handleLine(jsonEncode(call(2, 'gita_clone', {'address': 'git@github.com:acme/api.git'})));
    expect(seen.single, ['clone', 'git@github.com:acme/api.git', '--json']);
  });

  test('the tools that change things map to the right gita commands', () async {
    final seen = <List<String>>[];
    final server = GitaMcpServer(
      output: StringBuffer(),
      run: (args) async {
        seen.add(args);
        return (exitCode: 0, out: '{"ok":true}', err: '');
      },
    );
    Future<List<String>> args(String tool, Map<String, Object> a) async {
      seen.clear();
      final reply = await server.handleLine(jsonEncode(call(1, tool, a)));
      expect(reply!['error'], isNull, reason: '$tool: ${reply['error']}');
      return seen.single;
    }

    expect(await args('gita_setup', {}), ['setup', '--json', '--']);
    expect(
      await args('gita_setup', {
        'folders': ['/p/a', ' /p/b '],
        'only': ['me@acme.com'],
        'track': false,
      }),
      ['setup', '--only', 'me@acme.com', '--no-track', '--json', '--', '/p/a', '/p/b'],
    );
    expect(await args('gita_profile_add', {'name': 'Jane', 'email': 'j@acme.com', 'label': 'Work', 'folders': ['/w']}),
        ['profile', '--name', 'Jane', '--email', 'j@acme.com', '--label', 'Work', '--folder', '/w', 'add', '--json']);
    expect(await args('gita_profile_edit', {'profile': '--evil', 'githubLogin': 'jane'}),
        ['profile', '--github-login', 'jane', '--json', '--', 'edit', '--evil'],
        reason: 'a name starting with -- is not read as an option');
    expect(await args('gita_rules', {}), ['rule', 'list', '--json']);
    expect(await args('gita_rule_add', {'profile': 'Work', 'owner': 'acme'}),
        ['rule', '--profile', 'Work', '--owner', 'acme', 'add', '--json']);
    expect(await args('gita_rule_remove', {'rule': 'github.com/acme'}),
        ['rule', '--json', '--', 'remove', 'github.com/acme']);
    expect(await args('gita_company_import', {'file': '/c/acme.gita.json'}),
        ['company', '--json', '--', 'import', '/c/acme.gita.json']);
    expect(await args('gita_guard', {'action': 'install', 'path': '/p/a'}), ['guard', '--json', '--', 'install', '/p/a']);
    expect(await args('gita_sign_in', {'profile': 'Work'}), ['sign-in', '--profile', 'Work', '--no-wait', '--json']);
    expect(await args('gita_doctor', {'fix': true}), ['doctor', '--fix', '--json']);
    expect(await args('gita_doctor', {}), ['doctor', '--json']);

    for (final bad in [
      call(1, 'gita_guard', {'action': 'delete', 'path': '/p'}),
      call(2, 'gita_profile_add', {'name': 'Jane'}),
      call(3, 'gita_rule_remove', {}),
      call(4, 'gita_sign_in', {}),
    ]) {
      final reply = await server.handleLine(jsonEncode(bad));
      expect((reply!['error'] as Map)['code'], -32602, reason: '$bad');
    }
  });

  test('Claude can set Gita up from scratch through the tools', () async {
    Future<void> repo(String path, String email) async {
      final dir = Directory(path)..createSync(recursive: true);
      for (final args in [
        ['init', '-q'],
        ['config', 'user.email', email],
        ['config', 'user.name', 'Dev'],
      ]) {
        expect((await git.raw(args, workingDir: dir.path)).exitCode, 0);
      }
    }

    final projects = p.join(home.path, 'Projects');
    await repo(p.join(projects, 'work', 'api'), 'dev@acme.com');
    await repo(p.join(projects, 'work', 'web'), 'dev@acme.com');
    await repo(p.join(projects, 'mine', 'blog'), 'me@gmail.com');
    final other = p.join(home.path, 'Elsewhere');
    Directory(other).createSync();

    final replies = await talk([
      call(1, 'gita_setup', {'folders': [projects], 'only': ['dev@acme.com']}),
      call(2, 'gita_profile_add', {'name': 'Me', 'email': 'me@gmail.com', 'label': 'Personal', 'folders': [other]}),
      call(3, 'gita_rule_add', {'profile': 'Personal', 'owner': 'my-gh'}),
      call(4, 'gita_profile_edit', {'profile': 'Personal', 'githubLogin': 'my-gh'}),
      call(5, 'gita_rules'),
      call(6, 'gita_rule_remove', {'rule': 'github.com/my-gh'}),
      call(7, 'gita_profiles'),
      call(8, 'gita_check', {'path': p.join(projects, 'work', 'api')}),
      call(9, 'gita_doctor', {'fix': true}),
      call(10, 'gita_setup', {'folders': [projects], 'only': ['nobody@x.com']}),
    ]);
    Map<String, dynamic> body(int i) {
      final result = replies[i]['result'] as Map<String, dynamic>;
      final json = jsonDecode((result['content'] as List).single['text'] as String) as Map<String, dynamic>;
      return {...json, 'isError': result['isError']};
    }

    final setup = body(0);
    expect(setup['ok'], isTrue, reason: '$setup');
    expect(setup['profiles'], hasLength(1));
    expect(setup['profiles'][0]['email'], 'dev@acme.com');
    expect(setup['projects'], 2);
    expect(setup['needSignIn'], [setup['profiles'][0]['id']]);

    final added = body(1);
    expect(added['ok'], isTrue, reason: '$added');
    expect(added['profile']['label'], 'Personal');

    expect(body(2)['ok'], isTrue, reason: '${body(2)}');
    expect(body(3)['profile']['githubLogin'], 'my-gh');

    final rules = (body(4)['rules'] as List).cast<Map<String, dynamic>>();
    expect(rules.where((r) => r['kind'] == 'account').single['covers'], 'github.com/my-gh');
    expect(rules.where((r) => r['kind'] == 'folder').map((r) => r['profile']), containsAll(['Personal']));

    expect(body(5)['ok'], isTrue);
    final profiles = (body(6)['profiles'] as List).cast<Map<String, dynamic>>();
    expect(profiles.map((x) => x['email']), unorderedEquals(['dev@acme.com', 'me@gmail.com']));
    expect(profiles.firstWhere((x) => x['label'] == 'Personal')['accounts'], isEmpty);

    final check = body(7);
    expect(check['expectedProfile']['email'], 'dev@acme.com', reason: '$check');

    expect(body(8)['fixed'], isA<List<dynamic>>());

    final unknown = body(9);
    expect(unknown['isError'], isTrue);
    expect(unknown['error'], contains('dev@acme.com'), reason: 'says which accounts it did find');

    // git itself now uses the work account in the work projects.
    final email = await git.raw(['config', 'user.email'], workingDir: p.join(projects, 'work', 'api'));
    expect(email.stdout.toString().trim(), 'dev@acme.com');
  });

  group('mcp add-to-claude', () {
    void installCli() {
      File(paths.cliPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('');
    }

    test('registers the installed gita with Claude Code', () async {
      installCli();
      expect(await cli().run(['mcp', 'add-to-claude']), 0, reason: '$err');
      expect(processCalls, [
        ['claude', 'mcp', 'remove', '--scope', 'user', 'gita'],
        ['claude', 'mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'gita', '--', paths.cliPath, 'mcp'],
      ]);
      expect(out.toString(), contains('Done'));
    });

    test('says how to do it by hand when Claude Code is missing', () async {
      installCli();
      fakeProcess = (_, _) => throw const ProcessException('claude', []);
      expect(await cli().run(['mcp', 'add-to-claude']), 1);
      expect(err.toString(), contains("isn't installed"));
      expect(err.toString(), contains('claude mcp add'));
    });

    test('a shell that cannot find claude counts as missing', () async {
      installCli();
      fakeProcess = (_, _) => ProcessResult(0, 1, '', "'claude' is not recognized as an internal or external command");
      expect(await cli().run(['mcp', 'add-to-claude', '--json']), 1);
      final json = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(json['ok'], isFalse);
      expect(json['command'], contains(paths.cliPath));
      expect(json.containsKey('error'), isFalse);
    });

    test('refuses when gita is not installed (running from source)', () async {
      expect(await cli().run(['mcp', 'add-to-claude']), 2);
      expect(err.toString(), contains('Open the Gita app once'));
      expect(processCalls, isEmpty);
    });

    test('unknown subcommand is a usage error', () async {
      expect(await cli().run(['mcp', 'frobnicate']), 2);
    });
  });
}
