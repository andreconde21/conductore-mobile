import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android backup and device transfer would copy the app's files in clear
/// (widget state, queued notification actions) and restore secure-storage
/// ciphertext that the new device's Keystore cannot read.
void main() {
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();

  test('the app opts out of Android backup', () {
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test('Android 12+ extraction rules exclude every domain', () {
    final rules = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section>([\\s\\S]*?)</$section>',
      ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: section);
      for (final domain in [
        'root',
        'file',
        'database',
        'sharedpref',
        'external',
      ]) {
        expect(
          body,
          contains('<exclude domain="$domain" path="." />'),
          reason: '$section $domain',
        );
      }
      expect(body, isNot(contains('<include')), reason: section);
    }
  });
}
