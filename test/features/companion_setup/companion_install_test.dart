import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/companion_setup/data/companion_bundle.dart';
import 'package:conduit/features/companion_setup/data/companion_commands.dart';
import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'companion_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSftpSession sftp;
  late MatchingRunner runner;
  late CompanionSetupController controller;
  final host = buildHost('box');

  setUp(() {
    sftp = FakeSftpSession(home: '/home/andre', tree: {});
    runner = MatchingRunner({
      'mkdir -p': ok(''),
      'install.sh': ok(
        '{"ok":true,"settings":"/home/andre/.claude/settings.json"}\n',
      ),
      'exec node --version': ok('v22.1.0'),
      'conductore-hostd version': notFound,
    });
    controller = CompanionSetupController(
      runnerFactory: (_) => runner,
      sftpRepository: FakeSftpRepository(sftp),
      loadBundle: () async => fakeBundle(),
    );
  });

  tearDown(() => controller.dispose());

  test('install uploads the archive, unpacks it, runs install.sh, then '
      're-checks', () async {
    expect((await controller.refresh(host)).state, CompanionState.notInstalled);
    // After install.sh the companion answers like a healthy install.
    runner.responses.addAll(healthyResponses(daemon: false));
    runner.commands.clear();

    final log = <String>[];
    final outcome = await controller.install(host, onLog: log.add);

    const dir = '/home/andre/.local/share/conductore-src/0.3.0';
    expect(outcome.ok, isTrue);
    expect(outcome.directory, dir);
    // One archive, never loose scripts (App Store Connect rejects those).
    expect(sftp.writtenFiles.keys, {'$dir/companion.tar.gz'});
    expect(utf8.decode(sftp.writtenFiles['$dir/companion.tar.gz']!), 'archive');
    expect(sftp.closeCalls, 1);

    // mkdir before upload, install.sh after, then the status check.
    final mkdir = runner.commands.indexWhere((c) => c.contains('mkdir -p'));
    final install = runner.commands.indexWhere((c) => c.contains('install.sh'));
    final recheck = runner.commands.lastIndexWhere(
      (c) => c.contains('conductore-hostd doctor'),
    );
    expect(mkdir, 0);
    expect(runner.commands[mkdir], contains(dir));
    expect(install, greaterThan(mkdir));
    final command = runner.commands[install];
    expect(command, contains("cd '\\''$dir'\\'' || exit 1"));
    expect(command, contains('tar -xzf companion.tar.gz'));
    expect(command, contains('tar not found on PATH'));
    expect(command, contains('${'a' * 64}  install.sh'));
    expect(command, contains('${'d' * 64}  lib/cli.js'));
    expect(command, contains('sha256sum -c'));
    expect(command, contains('shasum -a 256 -c'));
    expect(command, endsWith("exec sh install.sh'"));
    expect(
      command.indexOf('tar -xzf'),
      lessThan(command.indexOf('exec sh install.sh')),
    );
    expect(recheck, greaterThan(install));

    expect(
      controller.statusFor(host)?.state,
      CompanionState.waitingForFirstEvent,
    );
    expect(log.first, contains('Uploading companion 0.3.0 (4 files, 1 KB)'));
    expect(log, contains('Installed.'));
  });

  test('a failing install.sh reports failure with its output', () async {
    runner.responses['install.sh'] = failed(
      1,
      stderr: 'node not found on PATH; Claude Code needs Node.js too',
    );
    final outcome = await controller.install(host);
    expect(outcome.ok, isFalse);
    expect(outcome.exitCode, 1);
    expect(outcome.log.join('\n'), contains('node not found on PATH'));
    expect(outcome.log.last, contains('install.sh failed (exit 1)'));
    // Still re-checked so the screen reflects reality.
    expect(controller.statusFor(host)?.state, CompanionState.notInstalled);
  });

  test('uninstall uploads, unpacks and runs install.sh --uninstall', () async {
    final outcome = await controller.uninstall(host);
    expect(outcome.ok, isTrue);
    expect(sftp.writtenFiles.keys.single, endsWith('/companion.tar.gz'));
    final command = runner.commands.firstWhere((c) => c.contains('install.sh'));
    expect(command, contains('tar -xzf companion.tar.gz'));
    expect(command, endsWith("exec sh install.sh --uninstall'"));
  });

  test('stop daemon runs conductore-hostd stop', () async {
    runner.responses.addAll(healthyResponses());
    runner.responses['conductore-hostd stop'] = ok(
      '{"ok":true,"running":true,"stopped":true}',
    );
    expect(await controller.stopDaemon(host), isTrue);
    expect(runner.ran('conductore-hostd stop'), isTrue);
  });

  test('send test event pipes JSON into conductore-hook and finds the '
      'agent', () async {
    runner.responses.addAll({
      'conductore-hook Notification': ok(''),
      ...healthyResponses(),
    });
    runner.responses['conductore-hostd status'] = ok(
      statusJson(
        source: 'daemon',
        seq: 2,
        agents: [
          agent('conductore-test', state: 'ended', updatedAt: DateTime.now()),
        ],
      ),
    );
    final result = await controller.sendTestEvent(host);
    expect(result.ok, isTrue);
    expect(result.message, contains('pruned after an hour'));
    final sent = runner.commands.firstWhere(
      (c) => c.contains('conductore-hook Notification'),
    );
    expect(sent, contains(r'\"session_id\":\"conductore-test\"'));
    expect(sent, contains(r'\"message\":\"Test from Conductore\"'));
    expect(sent, contains('conductore-hook SessionEnd'));
  });

  test('send test event reports a missing agent', () async {
    runner.responses.addAll({
      'conductore-hook Notification': ok(''),
      ...healthyResponses(),
    });
    final result = await controller.sendTestEvent(host);
    expect(result.ok, isFalse);
    expect(result.message, contains('hostd.log'));
  });

  test('status is cached per connection and reset when it changes', () async {
    final runners = <MatchingRunner>[];
    final cached = CompanionSetupController(
      runnerFactory: (_) {
        final r = MatchingRunner(healthyResponses());
        runners.add(r);
        return r;
      },
      sftpRepository: FakeSftpRepository(sftp),
      loadBundle: () async => fakeBundle(),
    );
    addTearDown(cached.dispose);

    cached.ensureChecked(host);
    cached.ensureChecked(host);
    await pumpEventQueue();
    expect(cached.statusFor(host)?.state, CompanionState.active);
    cached.ensureChecked(host);
    await pumpEventQueue();
    expect(runners, hasLength(1));
    expect(
      runners.single.commands.where((c) => c.contains('hostd version')),
      hasLength(1),
    );

    final moved = host.copyWith(host: '10.0.0.9');
    expect(cached.statusFor(moved), isNull);
    await cached.refresh(moved);
    expect(runners, hasLength(2));
    expect(runners.first.closeCount, 1);
  });

  group('bundled assets', () {
    test('the archive holds host/ byte for byte and the manifest sums '
        'match', () async {
      final bundle = await CompanionBundle.load(rootBundle);
      final package =
          jsonDecode(File('host/package.json').readAsStringSync())
              as Map<String, Object?>;
      expect(bundle.version, package['version']);
      expect(bundle.archiveName, 'companion.tar.gz');

      // Fails when host/ changed without re-running
      // tools/bundle-companion.sh.
      final hostFiles = [
        for (final dir in ['bin', 'lib', 'vendor'])
          if (Directory('host/$dir').existsSync())
            for (final entity in Directory(
              'host/$dir',
            ).listSync(recursive: true))
              if (entity is File)
                entity.path.substring('host/'.length).replaceAll(r'\\', '/'),
        'install.sh',
        'package.json',
        'README.md',
      ];
      expect(
        hostFiles,
        containsAll([
          'bin/conductore-hostd',
          'bin/conductore-hook',
          'bin/conductore-statusline',
          'lib/cli.js',
        ]),
      );
      final packed = untar(gzip.decode(bundle.archive));
      expect(packed.keys.toSet(), hostFiles.toSet());
      expect(bundle.checksums.keys.toSet(), hostFiles.toSet());
      for (final path in hostFiles) {
        final bytes = File('host/$path').readAsBytesSync();
        expect(
          packed[path],
          bytes,
          reason: '$path is stale: run tools/bundle-companion.sh',
        );
        expect(
          bundle.checksums[path],
          sha256.convert(bytes).toString(),
          reason: '$path: manifest.json is stale',
        );
      }
    });

    test('assets/companion holds no script or executable', () {
      // App Store Connect rejects any #! file in an iOS app as unsigned
      // code ("Code object is not signed at all"), executable or not.
      final files = [
        for (final entity in Directory(
          'assets/companion',
        ).listSync(recursive: true))
          if (entity is File) entity,
      ];
      expect(files.map((f) => f.uri.pathSegments.last).toSet(), {
        'companion.tar.gz',
        'manifest.json',
      });
    });

    test('no bundled asset starts with #!', () {
      for (final root in [
        'assets',
        'third_party/licenses',
        'third_party/notices',
      ]) {
        for (final entity in Directory(root).listSync(recursive: true)) {
          if (entity is! File) continue;
          final head = entity.openSync()..setPositionSync(0);
          final first = head.readSync(2);
          head.closeSync();
          expect(
            String.fromCharCodes(first),
            isNot('#!'),
            reason: '${entity.path} is a script: App Store Connect rejects it',
          );
        }
      }
    });
  });

  group('unpack command on a real shell', () {
    late Directory dir;
    final canRun =
        !Platform.isWindows &&
        Process.runSync('sh', ['-c', 'command -v tar']).exitCode == 0;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('companion-unpack');
      final src = Directory('${dir.path}/src')..createSync();
      Directory('${src.path}/bin').createSync();
      File('${src.path}/install.sh').writeAsStringSync(
        '#!/bin/sh\necho "install.sh ran with [\$*] in \$(pwd)"\n',
      );
      File('${src.path}/bin/tool').writeAsStringSync('tool\n');
      Process.runSync('tar', [
        '-czf',
        '${dir.path}/companion.tar.gz',
        '-C',
        src.path,
        'install.sh',
        'bin/tool',
      ]);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    List<String> sums({String? toolHash}) => CompanionBundle(
      version: '1',
      archive: Uint8List(0),
      checksums: {
        'install.sh': sha256
            .convert(File('${dir.path}/src/install.sh').readAsBytesSync())
            .toString(),
        'bin/tool':
            toolHash ?? sha256.convert(utf8.encode('tool\n')).toString(),
      },
    ).checksumLines;

    String onlySh() {
      final bin = Directory('${dir.path}/only-sh')..createSync();
      Link('${bin.path}/sh').createSync('/bin/sh');
      return bin.path;
    }

    ProcessResult run(String command, {Map<String, String>? env}) =>
        Process.runSync(
          '/bin/sh',
          ['-c', command],
          environment: env,
          includeParentEnvironment: env == null,
        );

    test('unpacks, verifies and runs install.sh', () {
      final result = run(
        CompanionCommands.unpackAndInstall(
          dir.path,
          archive: 'companion.tar.gz',
          checksumLines: sums(),
          uninstall: true,
        ),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('install.sh ran with [--uninstall]'));
      expect(File('${dir.path}/bin/tool').readAsStringSync(), 'tool\n');
    }, skip: !canRun);

    test('a checksum mismatch stops before install.sh', () {
      final result = run(
        CompanionCommands.unpackAndInstall(
          dir.path,
          archive: 'companion.tar.gz',
          checksumLines: sums(toolHash: '0' * 64),
        ),
      );
      expect(result.exitCode, 1);
      expect(result.stdout, isNot(contains('install.sh ran')));
      expect(result.stderr, contains('checksum mismatch'));
    }, skip: !canRun);

    test(
      'a host without tar gets a clear error',
      () {
        final result = run(
          CompanionCommands.unpackAndInstall(
            dir.path,
            archive: 'companion.tar.gz',
            checksumLines: sums(),
          ),
          // Only sh on PATH: no tar anywhere.
          env: {'PATH': onlySh(), 'HOME': dir.path},
        );
        expect(result.exitCode, 127);
        expect(result.stderr, contains('tar not found on PATH'));
        expect(result.stdout, isNot(contains('install.sh ran')));
      },
      skip: !canRun || File('/usr/local/bin/tar').existsSync(),
    );
  });
}

/// Reads the regular files of a ustar archive: path -> contents.
Map<String, List<int>> untar(List<int> tar) {
  final files = <String, List<int>>{};
  String field(int offset, int length) {
    final bytes = tar.sublist(offset, offset + length);
    final end = bytes.indexOf(0);
    return String.fromCharCodes(end < 0 ? bytes : bytes.sublist(0, end));
  }

  var at = 0;
  while (at + 512 <= tar.length && tar[at] != 0) {
    final name = field(at, 100);
    final prefix = field(at + 345, 155);
    final size = int.parse(field(at + 124, 12).trim(), radix: 8);
    final type = field(at + 156, 1);
    final path = prefix.isEmpty ? name : '$prefix/$name';
    if (type == '0' || type.isEmpty) {
      files[path] = tar.sublist(at + 512, at + 512 + size);
    }
    at += 512 + (size + 511) ~/ 512 * 512;
  }
  return files;
}
