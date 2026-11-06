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
    ]);
    for (final t in tools) {
      expect(t['description'], isNotEmpty);
      expect(t['inputSchema']['type'], 'object');
    }
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
