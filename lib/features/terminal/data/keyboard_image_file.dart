import 'dart:io';
import 'dart:math';

import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// What a keyboard may insert into the Chat composer: images from its
/// clipboard panel (Samsung Keyboard, Gboard) and its GIF and sticker
/// pickers, which Android delivers through commitContent rather than
/// the clipboard.
const keyboardImageMimeTypes = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/heic',
  'image/heif',
  'image/bmp',
];

/// Writes an image a keyboard inserted to
/// `<temp>/prompt-images/<id>/keyboard.<ext>`, the same place clipboard
/// images go, so it uploads like any other; null when the keyboard sent
/// no bytes (Flutter reads the content URI into [KeyboardInsertedContent.data]
/// on Android) or no image.
Future<SharedFile?> keyboardImageFile(
  KeyboardInsertedContent content, {
  Future<Directory> Function() tempDirectory = getTemporaryDirectory,
}) async {
  final data = content.data;
  if (data == null || data.isEmpty || !content.mimeType.startsWith('image/')) {
    return null;
  }
  final extension = switch (content.mimeType) {
    'image/jpeg' => 'jpg',
    'image/svg+xml' => 'svg',
    final type => type.substring('image/'.length),
  };
  final id =
      '${DateTime.now().microsecondsSinceEpoch}-'
      '${Random().nextInt(1 << 32).toRadixString(16)}';
  final dir = Directory('${(await tempDirectory()).path}/prompt-images/$id');
  await dir.create(recursive: true);
  final file = File('${dir.path}/keyboard.$extension');
  await file.writeAsBytes(data, flush: true);
  return SharedFile(
    path: file.path,
    name: 'keyboard.$extension',
    size: data.length,
    mimeType: content.mimeType,
  );
}
