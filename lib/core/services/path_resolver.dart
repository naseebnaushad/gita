import 'dart:io';

/// Resolves a folder path to its symlink-free canonical form.
///
/// macOS in particular symlinks common paths (`/tmp` -> `/private/tmp`),
/// and git's `gitdir:` matching in `includeIf` blocks is done against the
/// resolved path. Rule folder patterns and tracked repo paths must be
/// stored in the same resolved form as git uses, or includeIf silently
/// never matches.
String resolveRepoPath(String path) {
  final dir = Directory(path);
  final resolved = dir.existsSync() ? dir.resolveSymbolicLinksSync() : path;
  // Store a forward-slash canonical form: `Directory` returns native
  // separators (backslashes on Windows), but git always resolves
  // `rev-parse --show-toplevel` and `includeIf gitdir:` matching against
  // forward-slash paths. Keeping one canonical form end-to-end avoids
  // rules silently failing to match tracked repos or git's own config.
  return resolved.replaceAll('\\', '/');
}
