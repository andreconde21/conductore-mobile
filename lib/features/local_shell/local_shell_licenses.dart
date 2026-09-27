import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerLocalShellLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks([
      'Conductore - local shell (Termux tooling)',
    ], _notice);

    for (final license in _noticeAssets.entries) {
      yield LicenseEntryWithLineBreaks([
        'Conductore - local shell (${license.key})',
      ], await rootBundle.loadString(license.value));
    }
  });
}

const Map<String, String> _noticeAssets = {
  'GPL-2.0-only': 'third_party/licenses/GPL-2.0-only.txt',
  'GPL-3.0-or-later': 'third_party/licenses/GPL-3.0-or-later.txt',
  'LGPL-2.1-or-later': 'third_party/licenses/LGPL-2.1-or-later.txt',
  'LGPL-3.0-or-later': 'third_party/licenses/LGPL-3.0-or-later.txt',
  'xz': 'third_party/notices/xz.txt',
  'libandroid-shmem': 'third_party/notices/libandroid-shmem.txt',
  'libandroid-selinux': 'third_party/notices/libandroid-selinux.txt',
  'libandroid-glob': 'third_party/notices/libandroid-glob.txt',
  'PCRE2': 'third_party/notices/pcre2.txt',
};

const String _notice = '''
Builds of Conductore that include the on-device local Linux shell bundle
Android (aarch64) binaries that Conductore redistributes but did not create.
They are built from pinned Termux package recipes (https://termux.dev) and are
used under their respective open-source licenses:

  proot ................. GPL-2.0      (github.com/termux/proot)
  busybox ............... GPL-2.0      (busybox.net)
  GNU tar ............... GPL-3.0      (gnu.org/software/tar)
  liblzma ............... 0BSD         (tukaani.org/xz)
  xz tools .............. 0BSD         (tukaani.org/xz)
  libtalloc ............. LGPL-3.0     (talloc.samba.org)
  libacl / libattr ...... LGPL-2.1
  libiconv .............. LGPL-2.1     (gnu.org/software/libiconv)
  libandroid-shmem ...... BSD-3-Clause (github.com/termux)
  libandroid-selinux .... Public Domain
  libandroid-glob ....... BSD-3-Clause
  libpcre2 .............. BSD-3-Clause WITH PCRE2-exception

The downloadable root filesystems are packaged via Termux's proot-distro
(github.com/termux/proot-distro) and maintained by their upstream projects:
Arch Linux ARM (archlinuxarm.org), Debian, Ubuntu, Alpine Linux, Rocky Linux,
openSUSE, Void Linux, and Manjaro.

Conductore is based on Conduit by gwitko; both are Apache-2.0. These bundled
components and downloaded rootfs packages are not relicensed by either.

For GPL/LGPL components, Conductore publishes corresponding-source details,
exact upstream source archives, package checksums, pinned Termux package
recipes and patches, license texts, component notices, and binary rewrite notes
with the Conductore source repository:

  https://github.com/andreconde21/conductore-mobile

This is a written offer, valid for at least three years from distribution, to
give any third party a complete machine-readable copy of the corresponding
source for the GPL- and LGPL-licensed binaries, for the exact versions shipped,
for no more than the cost of distribution. The source is published at
https://github.com/andreconde21/conductore-mobile; requests may be sent to
Conductore's maintainer through that repository's issues.

See THIRD_PARTY_NOTICES.md and third_party/source-offer/README.md there.

Thank you to the Termux project and all upstream authors.''';
