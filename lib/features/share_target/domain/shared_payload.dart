/// One file handed over by the Android share sheet, already copied into the
/// app cache by the native side so it survives the granting intent.
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    this.size = 0,
    this.mimeType,
  });

  /// Absolute path of the cached copy on the phone.
  final String path;

  /// Display name from the content provider, already a single path segment.
  final String name;
  final int size;
  final String? mimeType;

  static SharedFile? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final path = raw['path'];
    if (path is! String || path.isEmpty) {
      return null;
    }
    final name = raw['name'];
    final size = raw['size'];
    final mimeType = raw['mimeType'];
    final fallbackName = path.split('/').where((s) => s.isNotEmpty).lastOrNull;
    return SharedFile(
      path: path,
      name: name is String && name.isNotEmpty ? name : fallbackName ?? 'shared',
      size: size is int ? size : (size is num ? size.toInt() : 0),
      mimeType: mimeType is String && mimeType.isNotEmpty ? mimeType : null,
    );
  }

  Map<String, Object?> toMap() => {
    'path': path,
    'name': name,
    'size': size,
    'mimeType': mimeType,
  };
}

/// What arrived from the share sheet: text and/or files.
class SharedPayload {
  const SharedPayload({
    this.text,
    this.subject,
    this.files = const [],
    this.unreadable = const [],
  });

  final String? text;
  final String? subject;
  final List<SharedFile> files;

  /// Names of shared streams the phone could not copy when the share
  /// arrived (the sending app revoked or never granted read access), so
  /// the user hears about them instead of the share vanishing.
  final List<String> unreadable;

  bool get hasText => text != null && text!.trim().isNotEmpty;
  bool get hasFiles => files.isNotEmpty;
  bool get isEmpty => !hasText && !hasFiles;

  /// Parses the native bridge map, dropping blank text and malformed files.
  /// Returns null when nothing usable remains.
  static SharedPayload? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final text = raw['text'];
    final subject = raw['subject'];
    final rawFiles = raw['files'];
    final rawUnreadable = raw['unreadable'];
    final files = rawFiles is List
        ? rawFiles.map(SharedFile.fromMap).whereType<SharedFile>().toList()
        : const <SharedFile>[];
    final trimmedText = text is String && text.trim().isNotEmpty
        ? text.trim()
        : null;
    final payload = SharedPayload(
      text: trimmedText,
      subject: subject is String && subject.trim().isNotEmpty
          ? subject.trim()
          : null,
      files: files,
      unreadable: rawUnreadable is List
          ? rawUnreadable.whereType<String>().toList()
          : const [],
    );
    return payload.isEmpty && payload.unreadable.isEmpty ? null : payload;
  }

  /// Short description for banners and pickers, e.g. "2 files and text".
  String get summary {
    final parts = <String>[];
    if (hasFiles) {
      parts.add(files.length == 1 ? files.first.name : '${files.length} files');
    }
    if (hasText) {
      parts.add('text');
    }
    return parts.join(' and ');
  }
}
