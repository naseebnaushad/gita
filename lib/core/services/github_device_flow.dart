import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// GitHub's OAuth device flow: the app shows a short code, the person
/// enters it on github.com in their browser, and the app receives an
/// access token. No password or token is ever typed into Gita.
///
/// See https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
class GitHubDeviceFlow {
  GitHubDeviceFlow({
    required this.clientId,
    GitHubHttp? http,
    Future<void> Function(Duration)? delay,
  })  : http = http ?? IoGitHubHttp(),
        _delay = delay ?? Future<void>.delayed;

  /// The OAuth app's client ID. Not a secret: desktop apps ship it in the
  /// binary, like the GitHub CLI does.
  final String clientId;

  final GitHubHttp http;
  final Future<void> Function(Duration) _delay;

  /// What a pushed-from token needs: `repo` to push to private repos,
  /// `workflow` so pushes that touch `.github/workflows` aren't rejected,
  /// and `read:user`/`user:email` to show who signed in and fill in the
  /// commit name and email.
  static const scopes = ['repo', 'workflow', 'read:user', 'user:email'];

  static final _deviceCodeUri = Uri.parse('https://github.com/login/device/code');
  static final _tokenUri = Uri.parse('https://github.com/login/oauth/access_token');
  static final _apiBase = Uri.parse('https://api.github.com/');

  /// Asks GitHub for a code to show the person.
  Future<DeviceCode> start() async {
    final json = await _post(_deviceCodeUri, {
      'client_id': clientId,
      'scope': scopes.join(' '),
    });
    _throwIfError(json);
    return DeviceCode(
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String,
      verificationUri: Uri.parse(json['verification_uri'] as String),
      expiresIn: Duration(seconds: (json['expires_in'] as num).toInt()),
      interval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
    );
  }

  /// Waits until the person approves [code] on github.com and returns the
  /// access token. Stops early, throwing [DeviceFlowException] with
  /// [DeviceFlowError.cancelled], once [isCancelled] returns true.
  Future<String> waitForToken(DeviceCode code, {bool Function()? isCancelled}) async {
    var interval = code.interval;
    final deadline = DateTime.now().add(code.expiresIn);
    while (true) {
      await _delay(interval);
      if (isCancelled?.call() ?? false) {
        throw const DeviceFlowException(DeviceFlowError.cancelled);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const DeviceFlowException(DeviceFlowError.expired);
      }
      final json = await _post(_tokenUri, {
        'client_id': clientId,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      final token = json['access_token'] as String?;
      if (token != null && token.isNotEmpty) return token;

      switch (json['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          // GitHub sends the new interval; fall back to adding 5 seconds.
          final next = (json['interval'] as num?)?.toInt();
          interval = next != null
              ? Duration(seconds: next)
              : interval + const Duration(seconds: 5);
          continue;
        default:
          _throwIfError(json);
          throw const DeviceFlowException(DeviceFlowError.unexpected);
      }
    }
  }

  /// Who [token] belongs to, plus their primary verified email if GitHub
  /// shares it.
  Future<GitHubAccount> fetchAccount(String token) async {
    final user = await _get('user', token);
    if (user is! Map<String, dynamic> || user['login'] is! String) {
      throw const DeviceFlowException(DeviceFlowError.unexpected);
    }
    String? email = user['email'] as String?;
    try {
      final emails = await _get('user/emails', token);
      if (emails is List) {
        for (final e in emails.whereType<Map<String, dynamic>>()) {
          if (e['primary'] == true && e['verified'] == true) {
            email = e['email'] as String?;
          }
        }
      }
    } on DeviceFlowException {
      // The email is only a convenience; the login is what matters.
    }
    return GitHubAccount(
      login: user['login'] as String,
      name: user['name'] as String?,
      email: email,
    );
  }

  Future<Map<String, dynamic>> _post(Uri uri, Map<String, String> form) async {
    final GitHubResponse response;
    try {
      response = await http.post(uri, form);
    } on Exception {
      throw const DeviceFlowException(DeviceFlowError.network);
    }
    if (response.statusCode == 404) {
      // GitHub answers 404 {"error":"Not Found"} for a client ID it doesn't know.
      throw const DeviceFlowException(DeviceFlowError.badClientId);
    }
    final body = _decode(response.body);
    if (body is Map<String, dynamic>) return body;
    throw const DeviceFlowException(DeviceFlowError.unexpected);
  }

  Future<Object?> _get(String path, String token) async {
    final GitHubResponse response;
    try {
      response = await http.get(_apiBase.resolve(path), token);
    } on Exception {
      throw const DeviceFlowException(DeviceFlowError.network);
    }
    if (response.statusCode != 200) {
      throw const DeviceFlowException(DeviceFlowError.unexpected);
    }
    return _decode(response.body);
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static void _throwIfError(Map<String, dynamic> json) {
    final error = json['error'] as String?;
    if (error == null) return;
    throw DeviceFlowException(switch (error) {
      'expired_token' || 'token_expired' => DeviceFlowError.expired,
      'access_denied' => DeviceFlowError.denied,
      'device_flow_disabled' => DeviceFlowError.deviceFlowDisabled,
      'incorrect_client_credentials' ||
      'unauthorized_client' =>
        DeviceFlowError.badClientId,
      _ => DeviceFlowError.unexpected,
    }, detail: json['error_description'] as String? ?? error);
  }
}

class DeviceCode {
  const DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;

  /// The short code the person types on github.com, e.g. `WDJB-MJHT`.
  final String userCode;
  final Uri verificationUri;
  final Duration expiresIn;
  final Duration interval;
}

class GitHubAccount {
  const GitHubAccount({required this.login, this.name, this.email});

  final String login;
  final String? name;
  final String? email;
}

enum DeviceFlowError {
  cancelled,
  expired,
  denied,
  deviceFlowDisabled,
  badClientId,
  network,
  unexpected,
}

class DeviceFlowException implements Exception {
  const DeviceFlowException(this.error, {this.detail});

  final DeviceFlowError error;
  final String? detail;

  /// A plain-language explanation with what to do next.
  String get message => switch (error) {
        DeviceFlowError.cancelled => 'Sign-in was cancelled.',
        DeviceFlowError.expired =>
          'The code ran out of time before it was entered. Start again to get a new code.',
        DeviceFlowError.denied =>
          'GitHub sign-in was declined in the browser. Start again and press Authorize.',
        DeviceFlowError.deviceFlowDisabled =>
          'This copy of Gita is set up with a GitHub app that has "Device '
              'Flow" turned off. Ask whoever manages Gita to turn it on in the '
              "app's GitHub settings, or paste an access token instead.",
        DeviceFlowError.badClientId =>
          "GitHub doesn't recognise the sign-in ID this copy of Gita uses. "
              'Ask whoever manages Gita to check it, or paste an access token instead.',
        DeviceFlowError.network =>
          "Couldn't reach GitHub. Check the internet connection and try again.",
        DeviceFlowError.unexpected =>
          'GitHub sent an unexpected answer${detail == null ? '' : ' ($detail)'}. '
              'Try again in a minute.',
      };

  @override
  String toString() => 'DeviceFlowException($error${detail == null ? '' : ': $detail'})';
}

class GitHubResponse {
  const GitHubResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// The two HTTP calls the device flow needs, so tests can fake GitHub.
abstract class GitHubHttp {
  /// Form POST that asks for a JSON answer.
  Future<GitHubResponse> post(Uri uri, Map<String, String> form);

  /// API GET authorised with [token].
  Future<GitHubResponse> get(Uri uri, String token);
}

class IoGitHubHttp implements GitHubHttp {
  IoGitHubHttp({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  static const _userAgent = 'gita-desktop';
  static const _timeout = Duration(seconds: 30);

  @override
  Future<GitHubResponse> post(Uri uri, Map<String, String> form) async {
    final request = await _client.postUrl(uri).timeout(_timeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
    request.write(Uri(queryParameters: form).query);
    return _read(await request.close().timeout(_timeout));
  }

  @override
  Future<GitHubResponse> get(Uri uri, String token) async {
    final request = await _client.getUrl(uri).timeout(_timeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    return _read(await request.close().timeout(_timeout));
  }

  static Future<GitHubResponse> _read(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join().timeout(_timeout);
    return GitHubResponse(response.statusCode, body);
  }
}
