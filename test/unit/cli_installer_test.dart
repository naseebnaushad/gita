import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/cli_installer.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late PlatformPaths paths;
  late String bundle;
  final exeName = Platform.isWindows ? 'gita.exe' : 'gita';

  void writeBundled(String relative, String content) {
    final file = File(p.join(bundle, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('gita_cli_installer_');
    paths = PlatformPaths(overrideHomeDir: p.join(tmp.path, 'home'));
    bundle = p.join(tmp.path, 'app', 'cli');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  CliInstaller installer() => CliInstaller(paths: paths, bundledDir: bundle);

  test('does nothing when the app does not ship the command', () async {
    final result = await installer().install();

    expect(result.status, CliInstallStatus.notBundled);
    expect(Directory(paths.gitaDir).existsSync(), isFalse);
  });

  test('installs bin and lib into ~/.gita on first start', () async {
    writeBundled('bin/$exeName', 'v1');
    writeBundled('lib/native.dll', 'lib v1');
    writeBundled('README.txt', 'not copied');

    final result = await installer().install();

    expect(result.status, CliInstallStatus.installed);
    expect(result.changed, isTrue);
    expect(File(paths.cliPath).readAsStringSync(), 'v1');
    expect(File(p.join(paths.gitaDir, 'lib', 'native.dll')).readAsStringSync(), 'lib v1');
    expect(File(p.join(paths.gitaDir, 'README.txt')).existsSync(), isFalse);
    expect(Directory(p.join(paths.gitaDir, 'bin')).listSync().map((e) => p.basename(e.path)),
        [exeName], reason: 'no .new/.old files left behind');
  });

  test('two installs at once take turns instead of clashing', () async {
    writeBundled('bin/$exeName', 'v1');

    final results = await Future.wait([installer().install(), installer().install()]);

    expect(results.map((r) => r.status),
        [CliInstallStatus.installed, CliInstallStatus.upToDate]);
    expect(File(paths.cliPath).readAsStringSync(), 'v1');
  });

  test('leaves a matching copy alone', () async {
    writeBundled('bin/$exeName', 'v1');
    await installer().install();
    final before = File(paths.cliPath).lastModifiedSync();

    final result = await installer().install();

    expect(result.status, CliInstallStatus.upToDate);
    expect(result.changed, isFalse);
    expect(File(paths.cliPath).lastModifiedSync(), before);
  });

  test('replaces an older copy', () async {
    writeBundled('bin/$exeName', 'v1');
    await installer().install();
    writeBundled('bin/$exeName', 'v2 is longer');

    final result = await installer().install();

    expect(result.status, CliInstallStatus.updated);
    expect(File(paths.cliPath).readAsStringSync(), 'v2 is longer');
  });

  test('replaces a same-size copy with different content', () async {
    writeBundled('bin/$exeName', 'aaaa');
    await installer().install();
    writeBundled('bin/$exeName', 'bbbb');

    expect((await installer().install()).status, CliInstallStatus.updated);
    expect(File(paths.cliPath).readAsStringSync(), 'bbbb');
  });

  test('cleans up an old copy left over from a previous update', () async {
    writeBundled('bin/$exeName', 'v1');
    await installer().install();
    File('${paths.cliPath}.old').writeAsStringSync('stale');
    writeBundled('bin/$exeName', 'v2');

    await installer().install();

    expect(File('${paths.cliPath}.old').existsSync(), isFalse);
  });

  test('a copy that fails is reported, not thrown', () async {
    writeBundled('bin/$exeName', 'v1');
    // A folder where the command should go can't be replaced by a file.
    Directory(paths.cliPath).createSync(recursive: true);
    File(p.join(paths.cliPath, 'keep')).writeAsStringSync('x');

    final result = await installer().install();

    expect(result.status, CliInstallStatus.failed);
    expect(result.message, contains(paths.gitaDir));
  });
}
