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
    expect(resolved, real.resolveSymbolicLinksSync());

    await link.delete();
    await real.delete(recursive: true);
  });

  test('resolveRepoPath returns the input unchanged when the path does not exist', () {
    const missing = '/definitely/does/not/exist/gita';
    expect(resolveRepoPath(missing), missing);
  });
}
