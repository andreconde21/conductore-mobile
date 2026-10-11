import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// The host side of `flutter drive` for integration_test/smoke_test.dart:
/// writes each screenshot the test takes to $SMOKE_OUT (tools/smoke-test.sh).
Future<void> main() async {
  final out = Directory(Platform.environment['SMOKE_OUT'] ?? 'build/smoke');
  await out.create(recursive: true);
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      await File('${out.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
