import 'dart:convert';
import 'dart:io';

/// The companion's `--gzip` flag: appended last to a command, it lets a
/// reply over 4 KB come back as `{"encoding":"gzip","data":"<base64>"}`,
/// the gzipped JSON (a transcript page or a usage report shrinks about
/// 3–4×). Older companions ignore the flag and answer plain JSON.
const companionGzipFlag = '--gzip';

/// [raw] as the plain JSON reply: a packed reply is unpacked, anything
/// else (plain JSON, errors, text) is returned as it is.
String unpackCompanionReply(String raw) {
  final text = raw.trimLeft();
  if (!text.startsWith('{"encoding":"gzip"')) return raw;
  try {
    final json = jsonDecode(text);
    if (json is Map && json['encoding'] == 'gzip' && json['data'] is String) {
      return utf8.decode(
        gzip.decode(base64.decode(json['data'] as String)),
        allowMalformed: true,
      );
    }
  } catch (_) {
    // Not a packed reply after all: let the caller's parser say so.
  }
  return raw;
}
