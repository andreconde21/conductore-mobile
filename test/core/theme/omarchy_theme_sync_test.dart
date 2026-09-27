import 'dart:async';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/omarchy_colors.dart';
import 'package:conduit/core/theme/omarchy_theme_sync.dart';
import 'package:conduit/core/theme/omarchy_theme_sync_controller.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

String _probeOutput({
  String name = 'everforest',
  String colors = '',
  String alacritty = '',
  bool lightMode = false,
  String font = 'JetBrainsMono Nerd Font',
}) =>
    '@@name\n$name\n@@colors\n$colors\n@@alacritty\n$alacritty\n'
    '@@lightmode\n${lightMode ? 'yes' : ''}\n@@font\n$font\n@@end\n';

String _fixture(String path) =>
    File('test/fixtures/omarchy/$path').readAsStringSync();

class _ProbeRunner implements AgentCommandRunner {
  _ProbeRunner(this.reply);

  FutureOr<String> Function() reply;
  final commands = <String>[];
  var closed = 0;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    return AgentCommandResult(stdout: await reply(), stderr: '', exitCode: 0);
  }

  @override
  Future<void> close() async => closed++;
}

SavedHost _host(String id, {SshAuthMethod auth = SshAuthMethod.privateKey}) =>
    SavedHost(
      id: id,
      name: 'pc-$id',
      host: '$id.lan',
      port: 22,
      username: 'andre',
      authMethod: auth,
    );

void main() {
  group('probe parsing', () {
    test('a bundled theme name maps to the bundled palette', () {
      final probe = parseOmarchyProbe(
        _probeOutput(name: 'tokyo-night', colors: 'accent = "#000000"'),
      )!;
      expect(probe.themeName, 'tokyo-night');
      expect(paletteForOmarchyProbe(probe), AppPalette.tokyoNight);
      expect(probe.fontFamily, 'JetBrainsMono Nerd Font');
    });

    test('an unknown theme is read from its colors.toml', () {
      final probe = parseOmarchyProbe(
        _probeOutput(
          name: 'my-dusk',
          colors: _fixture('custom/my-dusk/colors.toml'),
        ),
      )!;
      final palette = paletteForOmarchyProbe(probe)!;
      expect(palette.custom, isTrue);
      expect(palette.label, 'My Dusk');
      expect(palette.id, 'omarchy-custom:my-dusk');
      expect(palette.isDark, isTrue);
      expect(palette.canvas, const Color(0xFF1B1726));
      expect(palette.accent, const Color(0xFFE0A458));
      final terminal = palette.terminalTheme;
      expect(terminal.red, const Color(0xFFE06C75));
      expect(terminal.brightBlack, const Color(0xFF5C5470));
      expect(terminal.brightWhite, const Color(0xFFFFFFFF));
      // Omarchy derives missing bright colours 20% toward white.
      expect(
        terminal.brightRed,
        mixOmarchyColor(const Color(0xFFE06C75), const Color(0xFFFFFFFF), 0.2),
      );
    });

    test('a light.mode file makes a custom theme light', () {
      final probe = parseOmarchyProbe(
        _probeOutput(
          name: 'my-dusk',
          colors: _fixture('custom/my-dusk/colors.toml'),
          lightMode: true,
        ),
      )!;
      expect(paletteForOmarchyProbe(probe)!.brightness, Brightness.light);
    });

    test('a theme from before colors.toml is read from alacritty.toml', () {
      final probe = parseOmarchyProbe(
        _probeOutput(
          name: 'old-alacritty',
          alacritty: _fixture('custom/old-alacritty/alacritty.toml'),
        ),
      )!;
      final palette = paletteForOmarchyProbe(probe)!;
      expect(palette.canvas, const Color(0xFFF4EFE6));
      expect(palette.foreground, const Color(0xFF3B3228));
      expect(palette.accent, const Color(0xFF2F6B9A));
      // Background luminance decides the mode, as in Omarchy.
      expect(palette.isDark, isFalse);
      expect(palette.colors.selection, const Color(0xFFD9CBB4));
      expect(palette.terminalTheme.brightBlack, const Color(0xFFA8998A));
    });

    test('cut-off output, no Omarchy and unreadable themes give nothing', () {
      expect(parseOmarchyProbe('@@name\neverforest\n@@colors\n'), isNull);
      final none = parseOmarchyProbe('@@font\nDejaVu Sans Mono\n@@end\n')!;
      expect(none.hasOmarchy, isFalse);
      expect(paletteForOmarchyProbe(none), isNull);
      final broken = parseOmarchyProbe(
        _probeOutput(name: 'broken', colors: 'accent = "#123456"'),
      )!;
      expect(paletteForOmarchyProbe(broken), isNull);
    });
  });

  group('probe command', () {
    late Directory home;

    setUp(() => home = Directory.systemTemp.createTempSync('omarchy-home'));
    tearDown(() => home.deleteSync(recursive: true));

    Future<OmarchyProbeResult> runProbe() async {
      final result = await Process.run(
        'sh',
        ['-c', omarchyThemeProbeCommand],
        environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return parseOmarchyProbe(result.stdout as String)!;
    }

    test('reads the current layout (~/.local/state, theme.name)', () async {
      final current = Directory('${home.path}/.local/state/omarchy/current')
        ..createSync(recursive: true);
      final theme = Directory('${current.path}/theme')..createSync();
      File('${current.path}/theme.name').writeAsStringSync('my-dusk\n');
      File(
        '${theme.path}/colors.toml',
      ).writeAsStringSync(_fixture('custom/my-dusk/colors.toml'));
      File('${theme.path}/light.mode').writeAsStringSync('');

      final probe = await runProbe();
      expect(probe.themeName, 'my-dusk');
      expect(probe.lightModeFile, isTrue);
      expect(
        OmarchyColorResolver.parseColorsToml(probe.colorsToml)['color1'],
        '#e06c75',
      );
    });

    test('reads the older ~/.config/omarchy/current/theme symlink', () async {
      final themes = Directory('${home.path}/.config/omarchy/themes/nord')
        ..createSync(recursive: true);
      File('${themes.path}/alacritty.toml').writeAsStringSync('[colors]\n');
      final current = Directory('${home.path}/.config/omarchy/current')
        ..createSync(recursive: true);
      Link('${current.path}/theme').createSync(themes.path);

      final probe = await runProbe();
      expect(probe.themeName, 'nord');
      expect(paletteForOmarchyProbe(probe), AppPalette.nord);
    });

    test('reports no theme on a machine without Omarchy', () async {
      final probe = await runProbe();
      expect(probe.hasOmarchy, isFalse);
    });
  });

  group('sync controller', () {
    late ThemeController theme;
    late _ProbeRunner runner;
    late List<SavedHost> hosts;
    late DateTime now;
    late int runnersMade;

    OmarchyThemeSyncController controller() => OmarchyThemeSyncController(
      theme: theme,
      hosts: () async => hosts,
      runnerFactory: (host) {
        runnersMade++;
        return runner;
      },
      clock: () => now,
    );

    setUp(() async {
      theme = ThemeController(
        ThemePreferencesRepository(InMemorySecureStorage()),
      );
      await theme.load();
      await theme.setTerminalFont(TerminalFontOption.systemMonospace);
      runner = _ProbeRunner(() => _probeOutput(name: 'gruvbox'));
      hosts = [
        _host('a'),
        _host('b'),
        _host('key', auth: SshAuthMethod.hardwareKey),
      ];
      now = DateTime(2026, 9, 25, 12);
      runnersMade = 0;
    });

    test('following a machine applies its theme and font', () async {
      final sync = controller();
      expect(theme.palette, AppPalette.everforest);

      await sync.follow('a');

      expect(runner.commands.single, omarchyThemeProbeCommand);
      expect(runner.closed, 1);
      expect(theme.palette, AppPalette.gruvbox);
      expect(theme.selectedPalette, AppPalette.everforest);
      expect(theme.terminalFont, TerminalFontOption.jetBrainsMonoNerdFont);
      expect(theme.effectiveThemeMode, ThemeMode.dark);
      expect(sync.state, OmarchySyncState.synced);
      expect(sync.message, 'Gruvbox, JetBrainsMono Nerd Font');
    });

    test('follows a synced machine that is this desktop through '
        'findHost, though the machine list leaves it out', () async {
      final read = <String>[];
      final sync = OmarchyThemeSyncController(
        theme: theme,
        hosts: () async => hosts,
        findHost: (id) async => id == 'self'
            ? SavedHost.thisComputer(name: 'This computer · omarchy')
            : null,
        runnerFactory: (host) {
          read.add(host.id);
          return runner;
        },
        clock: () => now,
      );

      await sync.follow('self');

      expect(read, [thisComputerHostId]);
      expect(sync.state, OmarchySyncState.synced);
      expect(theme.palette, AppPalette.gruvbox);
    });

    test('picking another machine while one is still being read reads '
        'the new one', () async {
      final slow = Completer<String>();
      final replies = <FutureOr<String> Function()>[
        () => slow.future,
        () => _probeOutput(name: 'nord'),
      ];
      runner.reply = () => replies.removeAt(0)();
      final read = <String>[];
      final sync = OmarchyThemeSyncController(
        theme: theme,
        hosts: () async => hosts,
        runnerFactory: (host) {
          read.add(host.id);
          return runner;
        },
        clock: () => now,
      );

      final first = sync.follow('a');
      await pumpEventQueue();
      final second = sync.follow('b');
      await pumpEventQueue();
      slow.complete(_probeOutput(name: 'gruvbox'));
      await first;
      await second;

      expect(read, ['a', 'b']);
      expect(theme.omarchySyncHostId, 'b');
      expect(theme.palette, AppPalette.nord);
      expect(sync.state, OmarchySyncState.synced);
    });

    test('a custom theme and an unbundled font', () async {
      runner.reply = () => _probeOutput(
        name: 'my-dusk',
        colors: _fixture('custom/my-dusk/colors.toml'),
        font: 'CaskaydiaMono Nerd Font',
      );
      final sync = controller();
      await sync.follow('a');
      expect(theme.palette.id, 'omarchy-custom:my-dusk');
      expect(theme.terminalFont, TerminalFontOption.systemMonospace);
      expect(sync.message, contains('is not bundled'));
    });

    test('the synced theme is cached across restarts', () async {
      final storage = InMemorySecureStorage();
      theme = ThemeController(ThemePreferencesRepository(storage));
      await theme.load();
      runner.reply = () => _probeOutput(
        name: 'my-dusk',
        colors: _fixture('custom/my-dusk/colors.toml'),
      );
      await controller().follow('a');

      final restarted = ThemeController(ThemePreferencesRepository(storage));
      await restarted.load();
      expect(restarted.omarchySyncHostId, 'a');
      expect(restarted.palette, theme.palette);
      expect(restarted.palette.custom, isTrue);
    });

    test('resume syncs are throttled, explicit taps are not', () async {
      final sync = controller();
      await sync.follow('a');
      expect(runnersMade, 1);

      await sync.refresh();
      expect(runnersMade, 1);

      now = now.add(const Duration(minutes: 2));
      runner.reply = () => _probeOutput(name: 'nord');
      await sync.refresh();
      expect(runnersMade, 2);
      expect(theme.palette, AppPalette.nord);

      await sync.refresh(explicit: true);
      expect(runnersMade, 3);
    });

    test('security-key machines only sync on an explicit tap', () async {
      final sync = controller();
      await theme.setOmarchySyncHost('key');

      await sync.refresh();
      expect(runnersMade, 0);
      expect(sync.state, OmarchySyncState.needsTap);

      await sync.refresh(explicit: true);
      expect(runnersMade, 1);
      expect(theme.palette, AppPalette.gruvbox);
    });

    test('failures keep the current theme and say why', () async {
      final sync = controller();
      runner.reply = () => throw const AppFailure('Could not reach pc-a.');
      await sync.follow('a');
      expect(theme.palette, AppPalette.everforest);
      expect(sync.state, OmarchySyncState.failed);
      expect(sync.message, 'Could not reach pc-a.');

      now = now.add(const Duration(minutes: 5));
      runner.reply = () => '@@font\nmonospace\n@@end\n';
      await sync.refresh();
      expect(sync.message, 'No Omarchy theme found on pc-a.');

      await theme.setOmarchySyncHost('gone');
      await sync.refresh(explicit: true);
      expect(sync.message, 'That machine is no longer saved.');
    });

    test(
      'picking a theme stops following; switching drops a stale sync',
      () async {
        final sync = controller();
        final gate = Completer<String>();
        runner.reply = () => gate.future;
        final pending = sync.follow('a');
        while (runner.commands.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        await theme.setOmarchySyncHost('b');
        gate.complete(_probeOutput(name: 'nord'));
        await pending;
        expect(theme.palette, AppPalette.everforest);

        runner.reply = () => _probeOutput(name: 'nord');
        await sync.follow('b');
        expect(theme.palette, AppPalette.nord);

        await theme.setPalette(AppPalette.rosePine);
        expect(theme.omarchySyncHostId, isNull);
        expect(theme.palette, AppPalette.rosePine);
        expect(theme.effectiveThemeMode, ThemeMode.light);
      },
    );

    test('lists saved machines but not the local shell', () async {
      hosts = [
        _host('a'),
        SavedHost.localShell(id: 'local', name: 'Local shell'),
      ];
      expect((await controller().machines()).map((h) => h.id), ['a']);
    });
  });
}
