import 'dart:io';

import 'package:conduit/features/local_shell/data/rootfs_downloader.dart';
import 'package:conduit/features/local_shell/domain/rootfs_manifest.dart';
import 'package:conduit/features/local_shell/local_shell_config.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final archive = List<int>.generate(4096, (i) => i % 251);
  final pin = crypto.sha256.convert(archive).toString();

  RootfsManifest manifest() => rootfsManifest(
    version: 'test-aarch64',
    fileName: 'test-aarch64.tar.xz',
    sha256: pin,
    downloadSizeBytes: archive.length,
    primaryBaseUrl: 'https://primary.example/rel',
    fallbackBaseUrl: 'https://fallback.example/rel/',
  );

  late Directory temp;
  setUp(() async => temp = await Directory.systemTemp.createTemp('rootfs'));
  tearDown(() => temp.delete(recursive: true));

  Future<List<String>> download(
    Map<String, http.Response Function()> hosts,
  ) async {
    final asked = <String>[];
    final client = MockClient((request) async {
      asked.add(request.url.toString());
      final answer = hosts[request.url.host];
      return answer == null ? http.Response('', 404) : answer();
    });
    await HttpRootfsDownloader(
      client,
    ).download(manifest: manifest(), destination: '${temp.path}/rootfs.tar.xz');
    return asked;
  }

  test('the manifest lists the primary, then the fallback', () {
    expect(manifest().archiveUrls.map((u) => u.toString()), [
      'https://primary.example/rel/test-aarch64.tar.xz',
      'https://fallback.example/rel/test-aarch64.tar.xz',
    ]);
    // No --dart-define in tests: both default to upstream.
    final single = rootfsManifest(
      version: 'v',
      fileName: 'f.tar.xz',
      sha256: pin,
      downloadSizeBytes: 1,
    );
    expect(single.archiveUrls, hasLength(1));
    expect(single.archiveUrl.toString(), '$upstreamRootfsBaseUrl/f.tar.xz');
  });

  test('an unreachable primary falls back to the mirror', () async {
    final asked = await download({
      'fallback.example': () => http.Response.bytes(archive, 200),
    });
    expect(asked.map((u) => Uri.parse(u).host), [
      'primary.example',
      'fallback.example',
    ]);
    expect(await File('${temp.path}/rootfs.tar.xz').readAsBytes(), archive);
  });

  test('a primary serving other bytes fails the pin and the mirror is '
      'used', () async {
    await download({
      'primary.example': () =>
          http.Response.bytes(List<int>.filled(archive.length, 7), 200),
      'fallback.example': () => http.Response.bytes(archive, 200),
    });
    expect(await File('${temp.path}/rootfs.tar.xz').readAsBytes(), archive);
  });

  test('every source failing reports the last failure', () async {
    await expectLater(
      download({}),
      throwsA(
        isA<DownloadException>().having(
          (e) => e.kind,
          'kind',
          DownloadFailureKind.network,
        ),
      ),
    );
  });

  test('the shipped catalog pins the same files on every source', () {
    for (final distro in defaultLocalShellDistros()) {
      final names = distro.manifest.archiveUrls
          .map((u) => u.pathSegments.last)
          .toSet();
      expect(names, hasLength(1), reason: distro.id);
    }
  });
}
