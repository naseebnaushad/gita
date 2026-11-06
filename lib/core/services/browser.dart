import 'dart:io';

/// Opens [uri] in the default browser. Returns false if that failed, so the
/// caller can show the link for the person to open themselves.
Future<bool> openInBrowser(Uri uri) async {
  if (uri.scheme != 'https') return false;
  final url = uri.toString();
  try {
    final ProcessResult result;
    if (Platform.isWindows) {
      // rundll32 avoids cmd.exe, which would treat & in the URL specially.
      result = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else if (Platform.isMacOS) {
      result = await Process.run('open', [url]);
    } else {
      result = await Process.run('xdg-open', [url]);
    }
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
