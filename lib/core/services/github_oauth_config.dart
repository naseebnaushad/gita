import 'dart:io';

/// Client ID of the "Gita" GitHub OAuth app (owned by tbaiadmin, Device
/// Flow on). A client ID is not a secret; it only names the OAuth app
/// people approve on github.com, so desktop apps ship it in the binary.
const gitaGitHubClientId = 'Ov23licOLgsWLhLzch9w';

/// The GitHub OAuth app client ID that "Sign in with GitHub" uses.
///
/// Gita uses its own app ([gitaGitHubClientId]) unless a build picks
/// another one:
///
///     flutter build windows --dart-define=GITA_GITHUB_CLIENT_ID=Ov23li...
///
/// or, without rebuilding, the `GITA_GITHUB_CLIENT_ID` environment
/// variable (which wins over the built-in value). Building with
/// `--dart-define=GITA_GITHUB_CLIENT_ID=` (empty) hides sign-in, so people
/// paste a token instead.
const builtInGitHubClientId =
    String.fromEnvironment('GITA_GITHUB_CLIENT_ID', defaultValue: gitaGitHubClientId);

String? resolveGitHubClientId({
  Map<String, String>? environment,
  String builtIn = builtInGitHubClientId,
}) {
  final fromEnv = (environment ?? Platform.environment)['GITA_GITHUB_CLIENT_ID']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final value = builtIn.trim();
  return value.isEmpty ? null : value;
}
