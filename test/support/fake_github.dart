import 'dart:convert';

import 'package:gita/core/services/github_device_flow.dart';

/// Plays GitHub's side of the device flow from a script of answers.
class FakeGitHub implements GitHubHttp {
  FakeGitHub({required this.tokenAnswers, this.deviceAnswer, this.user, this.emails});

  /// Answers to successive polls of /login/oauth/access_token.
  final List<Map<String, Object?>> tokenAnswers;
  final GitHubResponse? deviceAnswer;
  final Map<String, Object?>? user;
  final List<Object?>? emails;

  final posts = <(Uri, Map<String, String>)>[];
  final gets = <(Uri, String)>[];
  var polls = 0;

  @override
  Future<GitHubResponse> post(Uri uri, Map<String, String> form) async {
    posts.add((uri, form));
    if (uri.path == '/login/device/code') {
      return deviceAnswer ??
          GitHubResponse(200, jsonEncode({
            'device_code': 'dev-123',
            'user_code': 'WDJB-MJHT',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 900,
            'interval': 5,
          }));
    }
    final answer = tokenAnswers[polls++];
    return GitHubResponse(200, jsonEncode(answer));
  }

  @override
  Future<GitHubResponse> get(Uri uri, String token) async {
    gets.add((uri, token));
    if (uri.path == '/user') return GitHubResponse(200, jsonEncode(user));
    if (uri.path == '/user/emails') {
      return emails == null
          ? const GitHubResponse(403, '{}')
          : GitHubResponse(200, jsonEncode(emails));
    }
    return const GitHubResponse(404, '{}');
  }
}
