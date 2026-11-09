import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/path_resolver.dart';

void main() {
  test('resolveRepoPath resolves symlinked ancestors to their real path', () async {
    final real = await Directory.systemTemp.createTemp('gita_real_');
    final linkPath = '${real.path}_link';
    final link = Link(linkPath);
    await link.create(real.path);

    final resolved = resolveRepoPath(linkPath);
    expect(resolved, real.resolveSymbolicLinksSync().replaceAll('\\', '/'));

    await link.delete();
    await real.delete(recursive: true);
  });

  test('resolveRepoPath resolves a not-yet-created folder through its existing parent', () async {
    // Like cloning into <symlinked folder>/new/api: the result must match
    // what git reports once the folder exists (/var -> /private/var on macOS).
    final real = await Directory.systemTemp.createTemp('gita_real_');
    final linkPath = '${real.path}_link';
    final link = Link(linkPath);
    await link.create(real.path);

    final resolved = resolveRepoPath('$linkPath/new/api');
    expect(resolved, '${real.resolveSymbolicLinksSync().replaceAll('\\', '/')}/new/api');

    await link.delete();
    await real.delete(recursive: true);
  });

  test('resolveRepoPath keeps a relative or ~ path that does not exist as typed', () {
    expect(resolveRepoPath('~/gita_no_such_dir/work'), '~/gita_no_such_dir/work');
    expect(resolveRepoPath('gita_no_such_dir/api'), 'gita_no_such_dir/api');
    expect(resolveRepoPath(''), '');
  });

  test('resolveRepoPath keeps glob characters after the existing part', () async {
    final real = await Directory.systemTemp.createTemp('gita_real_');
    final linkPath = '${real.path}_link';
    await Link(linkPath).create(real.path);

    expect(resolveRepoPath('$linkPath/**'),
        '${real.resolveSymbolicLinksSync().replaceAll('\\', '/')}/**');

    await Link(linkPath).delete();
    await real.delete(recursive: true);
  });

  test('resolveRepoPath returns the input unchanged when the path does not exist', () {
    const missing = '/definitely/does/not/exist/gita';
    expect(resolveRepoPath(missing), missing);
  });
}
