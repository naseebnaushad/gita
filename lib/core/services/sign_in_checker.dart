import 'dart:async';
import 'dart:convert';

import 'github_device_flow.dart';

/// Whether a saved GitHub sign-in still works.
enum SignInHealth {
  /// GitHub accepted it.
  working,

  /// GitHub refused it: it was cancelled, expired or mistyped.
  rejected,

  /// No clear answer (no internet, timeout, GitHub busy). Treated as fine,
  /// so people aren't sent to sign in again for nothing.
  unknown,
}

/// The answer from [SignInChecker.check].
class SignInCheck {
  const SignInCheck._(this.health, this.login);

  /// GitHub accepted the token; it belongs to [login].
  const SignInCheck.working(String login) : this._(SignInHealth.working, login);

  static const rejected = SignInCheck._(SignInHealth.rejected, null);
  static const unknown = SignInCheck._(SignInHealth.unknown, null);

  final SignInHealth health;

  /// The GitHub account the token belongs to, when it works.
  final String? login;
}

/// Asks whether a saved GitHub token still works. A port, so the core and
/// tests don't depend on the network.
abstract interface class SignInChecker {
  /// Checks [token]. Never throws; problems reaching GitHub give
  /// [SignInCheck.unknown].
  Future<SignInCheck> check(String token);
}

/// Checks a token with `GET https://api.github.com/user`: 200 means it
/// works, 401 means GitHub rejected it, anything else is unknown.
///
/// Answers are kept in memory for [cacheFor] per token, so reruns of the
/// Doctor don't repeat the request. A new sign-in has a new token, so the
/// cache never hides it.
class GitHubSignInChecker implements SignInChecker {
  GitHubSignInChecker({
    GitHubHttp? http,
    this.timeout = const Duration(seconds: 10),
    this.cacheFor = const Duration(minutes: 5),
    DateTime Function()? now,
  })  : http = http ?? IoGitHubHttp(),
        _now = now ?? DateTime.now;

  final GitHubHttp http;
  final Duration timeout;
  final Duration cacheFor;
  final DateTime Function() _now;
  final _cache = <String, ({DateTime at, SignInCheck result})>{};

  static final _userUri = Uri.parse('https://api.github.com/user');

  @override
  Future<SignInCheck> check(String token) async {
    if (token.isEmpty) return SignInCheck.rejected;
    final cached = _cache[token];
    if (cached != null && _now().difference(cached.at) < cacheFor) {
      return cached.result;
    }
    final result = await _ask(token);
    // Don't keep "unknown": the next run may reach GitHub.
    if (result.health != SignInHealth.unknown) {
      _cache[token] = (at: _now(), result: result);
    }
    return result;
  }

  Future<SignInCheck> _ask(String token) async {
    final GitHubResponse response;
    try {
      response = await http.get(_userUri, token).timeout(timeout);
    } on Exception {
      return SignInCheck.unknown;
    }
    if (response.statusCode == 401) return SignInCheck.rejected;
    if (response.statusCode != 200) return SignInCheck.unknown;
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['login'] is String) {
        return SignInCheck.working(body['login'] as String);
      }
    } on FormatException {
      // Fall through.
    }
    return SignInCheck.unknown;
  }
}
