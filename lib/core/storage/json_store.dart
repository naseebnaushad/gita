import 'dart:convert';
import 'dart:io';

/// Generic flat-JSON-file store for a list of records (plan §12 decision:
/// JSON over SQLite for v1). Writes atomically via a temp file + rename so a
/// crash mid-write can't corrupt the store.
class JsonStore<T> {
  JsonStore({
    required this.path,
    required this.fromJson,
    required this.toJson,
  });

  final String path;
  final T Function(Map<String, dynamic>) fromJson;
  final Map<String, dynamic> Function(T) toJson;

  Future<List<T>> readAll() async {
    final file = File(path);
    if (!await file.exists()) return [];
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) return [];
    final decoded = jsonDecode(contents) as List<dynamic>;
    return decoded
        .map((e) => fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<void> writeAll(List<T> items) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    final encoded = const JsonEncoder.withIndent('  ')
        .convert(items.map(toJson).toList(growable: false));
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }
}
