import 'dart:io';

/// The GitHub OAuth app client ID that "Sign in with GitHub" uses.
///
/// Set it when building Gita:
///
///     flutter build windows --dart-define=GITA_GITHUB_CLIENT_ID=Ov23li...
///
/// or, without rebuilding, with the `GITA_GITHUB_CLIENT_ID` environment
/// variable (which wins over the built-in value). A client ID is not a
/// secret; it only names the OAuth app people approve on github.com.
/// When neither is set, sign-in is hidden and people paste a token instead.
const builtInGitHubClientId = String.fromEnvironment('GITA_GITHUB_CLIENT_ID');

String? resolveGitHubClientId({Map<String, String>? environment}) {
  final fromEnv = (environment ?? Platform.environment)['GITA_GITHUB_CLIENT_ID']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final builtIn = builtInGitHubClientId.trim();
  return builtIn.isEmpty ? null : builtIn;
}
