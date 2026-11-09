import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves a folder path to its symlink-free canonical form.
///
/// macOS in particular symlinks common paths (`/tmp` -> `/private/tmp`,
/// `/var` -> `/private/var`), and git's `gitdir:` matching in `includeIf`
/// blocks is done against the resolved path. Rule folder patterns and
/// tracked repo paths must be stored in the same resolved form as git uses,
/// or includeIf silently never matches.
///
/// A path that doesn't exist yet (say, where a project is about to be
/// cloned) is resolved through its deepest existing folder, so it gets the
/// same form git will report once the folder is there.
String resolveRepoPath(String path) {
  // Only an absolute path is walked up to an existing parent. Anything
  // else that doesn't exist (`~/work`, `code/api`, an empty field) is kept
  // as typed: walking it up would end at `.` and silently prefix the app's
  // working directory. git expands `~` in `gitdir:` patterns itself.
  if (!p.isAbsolute(path) && !Directory(path).existsSync()) {
    return path.replaceAll('\\', '/');
  }
  var existing = path;
  final missing = <String>[];
  while (!Directory(existing).existsSync()) {
    final parent = p.dirname(existing);
    if (parent == existing) {
      // Nothing along the path exists; leave it as given.
      return path.replaceAll('\\', '/');
    }
    missing.insert(0, p.basename(existing));
    existing = parent;
  }
  final resolved = missing.isEmpty
      ? Directory(existing).resolveSymbolicLinksSync()
      : p.joinAll([Directory(existing).resolveSymbolicLinksSync(), ...missing]);
  // Store a forward-slash canonical form: `Directory` returns native
  // separators (backslashes on Windows), but git always resolves
  // `rev-parse --show-toplevel` and `includeIf gitdir:` matching against
  // forward-slash paths. Keeping one canonical form end-to-end avoids
  // rules silently failing to match tracked repos or git's own config.
  return resolved.replaceAll('\\', '/');
}
