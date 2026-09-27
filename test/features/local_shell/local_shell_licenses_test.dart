import 'package:conduit/features/local_shell/local_shell_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled local-shell notices are packaged as assets', () async {
    const assets = [
      'third_party/licenses/GPL-2.0-only.txt',
      'third_party/licenses/GPL-3.0-or-later.txt',
      'third_party/licenses/LGPL-2.1-or-later.txt',
      'third_party/licenses/LGPL-3.0-or-later.txt',
      'third_party/notices/xz.txt',
      'third_party/notices/libandroid-shmem.txt',
      'third_party/notices/libandroid-selinux.txt',
      'third_party/notices/libandroid-glob.txt',
      'third_party/notices/pcre2.txt',
    ];

    for (final asset in assets) {
      final text = await rootBundle.loadString(asset);
      expect(text.trim(), isNotEmpty, reason: asset);
    }
  });

  test('the GPL/LGPL written offer names Conductore\'s own source and keeps '
      'the Conduit credit', () async {
    registerLocalShellLicenses();
    final notice = await LicenseRegistry.licenses.firstWhere(
      (entry) =>
          entry.packages.contains('Conductore - local shell (Termux tooling)'),
    );
    final paragraphs = [for (final p in notice.paragraphs) p.text];
    final text = paragraphs.join('\n');

    expect(text, contains('Conduit by gwitko'));
    final offer = paragraphs
        .skipWhile((p) => !p.contains('written offer'))
        .take(3)
        .join('\n');
    expect(
      offer,
      contains('https://github.com/andreconde21/conductore-mobile'),
    );
    expect(
      paragraphs.where((p) => p.contains('github.com/gwitko/Conduit')),
      isEmpty,
      reason: 'the upstream repository is not where Conductore\'s source is',
    );
  });
}
