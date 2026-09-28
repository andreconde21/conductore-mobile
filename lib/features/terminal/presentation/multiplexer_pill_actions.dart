import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/live/presentation/live_host_hub.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_navigator.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/domain/tmux_navigator.dart';
import 'package:conduit/features/terminal/presentation/herdr_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/herdr_navigator_sheet.dart';
import 'package:conduit/features/terminal/presentation/widgets/tmux_navigator_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The multiplexer the pill's multiplexer button drives for a session.
enum PillMultiplexer { herdr, tmux }

/// Herdr for a session opened on a Herdr target; tmux for one the app
/// attaches to tmux (a tmux target, or a host that starts tmux on
/// connect); otherwise Herdr, which may run inside a plain shell.
PillMultiplexer pillMultiplexerOf(SavedHost host) {
  final target = ConnectTarget.fromSessionHostId(host.id);
  if (target?.kind == ConnectTargetKind.herdr) {
    return PillMultiplexer.herdr;
  }
  return host.startTmuxOnConnect ? PillMultiplexer.tmux : PillMultiplexer.herdr;
}

/// The tmux session a session's host attaches to (`tmux new-session -A -s`).
String tmuxSessionNameOf(SavedHost host) {
  final name = host.tmuxSessionName.trim();
  return name.isEmpty ? defaultTmuxSessionName : name;
}

/// One entry of the multiplexer button's long-press menu.
sealed class MultiplexerQuickPick {
  const MultiplexerQuickPick();
}

class HerdrQuickPick extends MultiplexerQuickPick {
  const HerdrQuickPick(this.kind);

  final HerdrNewPane kind;
}

class TmuxQuickPick extends MultiplexerQuickPick {
  const TmuxQuickPick(this.action);

  final TmuxQuickAction action;
}

/// The pill's multiplexer button: the Herdr or tmux navigator on tap, the
/// "new pane" menu on long-press. Every action goes through the host's CLI
/// over a command channel when it can, and falls back to the prefix keys
/// typed into the session.
mixin MultiplexerPillActions<T extends StatefulWidget> on State<T> {
  /// The session's key rows: controller, palette, prefix, callbacks.
  TerminalKeyboardBar get multiplexerKeyRows;

  /// Opens the command channel; null limits everything to keys.
  AgentCommandRunner Function(SavedHost host)? get multiplexerRunnerFactory;

  /// The machine's pushed Herdr state, when its companion pushes it.
  LiveHostFeed? Function(SavedHost host)? get multiplexerLiveFeed => null;

  /// Gives the terminal its focus back after a sheet or menu.
  void focusTerminalAfterMultiplexer();

  TerminalSessionController get _session => multiplexerKeyRows.controller;
  AppPalette get _mxPalette => multiplexerKeyRows.palette;
  Brightness get _mxBrightness => multiplexerKeyRows.brightness;
  MultiplexerPrefixKey get _prefix => multiplexerKeyRows.tmuxPrefixKey;

  PillMultiplexer get pillMultiplexer => pillMultiplexerOf(_session.host);

  /// Why the command channel cannot be used for this session's host, or
  /// null when it can.
  String? multiplexerUnavailableReason(SavedHost host) {
    if (host.isLocal) {
      return 'The pane list needs an SSH machine.';
    }
    if (multiplexerRunnerFactory == null) {
      return 'The pane list is not available here.';
    }
    if (host.authMethod == SshAuthMethod.hardwareKey) {
      return 'The pane list is off for security-key machines: every refresh '
          'would ask for a touch.';
    }
    return null;
  }

  AgentCommandRunner? _openRunner(SavedHost host) =>
      multiplexerUnavailableReason(host) == null
      ? multiplexerRunnerFactory!(host)
      : null;

  /// The Herdr server a tab opened on a named Herdr session talks to.
  String get _herdrSession {
    final target = ConnectTarget.fromSessionHostId(_session.host.id);
    return target?.kind == ConnectTargetKind.herdr ? target!.session : '';
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Tap on the multiplexer button.
  Future<void> openMultiplexerNavigator() => switch (pillMultiplexer) {
    PillMultiplexer.herdr => openHerdrNavigator(),
    PillMultiplexer.tmux => openTmuxNavigator(),
  };

  // ---------------------------------------------------------------- Herdr

  Future<void> openHerdrNavigator() async {
    final host = _session.host;
    final reason = multiplexerUnavailableReason(host);
    final runner = _openRunner(host);
    final cache = HerdrPaneListingCache.instance;
    final herdrSession = _herdrSession;
    try {
      final pick = await showHerdrNavigatorSheet(
        context: context,
        palette: _mxPalette,
        brightness: _mxBrightness,
        hostPrefix: _prefix,
        keymapHostId: baseHostId(host.id),
        cached: cache[host.id],
        paneListUnavailableReason: reason,
        showCdTo: multiplexerKeyRows.onOpenRecentDirectories != null,
        load: runner == null
            ? null
            : () async {
                // The machine's own Herdr bindings label the shortcuts
                // (read once per app run, read-only).
                final keymaps = HerdrKeymapCache.instance;
                if (!keymaps.has(baseHostId(host.id))) {
                  await keymaps.load(baseHostId(host.id), runner);
                }
                final feed = multiplexerLiveFeed?.call(host);
                final server = LiveHostModel.herdrServerId(herdrSession);
                // Pushed by the companion: no herdr command needed.
                final listing =
                    feed != null &&
                        feed.support == LiveSupport.supported &&
                        feed.model.serverState(server) == LiveServerState.up
                    ? HerdrPanesAvailable(
                        HerdrNavigator.buildEntries(
                          feed.model.workspaces(
                            server: server,
                            session: herdrSession,
                          ),
                          feed.model.herdrTabs(server: server),
                          feed.model.herdrAgents(server: server),
                        ),
                      )
                    : await HerdrNavigator.load(runner, session: herdrSession);
                if (listing is! HerdrListingFailed) {
                  cache[host.id] = listing;
                }
                return listing;
              },
      );
      switch (pick) {
        case null:
          focusTerminalAfterMultiplexer();
        case HerdrNewPanePick(:final kind):
          await createHerdrPane(kind, runner: runner);
        case HerdrTabPick(:final number):
          sendHerdrTab(_session, number, hostPrefix: _prefix);
          focusTerminalAfterMultiplexer();
        case HerdrShortcutPick(:final shortcut):
          if (shortcut.confirm && !await _confirm(shortcut.label, shortcut)) {
            focusTerminalAfterMultiplexer();
            return;
          }
          // Kill pane goes through the CLI when it can: it does not depend
          // on the server's bindings and skips Herdr's own confirm dialog
          // (the app just asked).
          if (shortcut == HerdrShortcut.closePane &&
              runner != null &&
              await HerdrRemoteControl.closeFocusedPaneOn(
                runner,
                HerdrCommands(herdrSession),
              )) {
            focusTerminalAfterMultiplexer();
            return;
          }
          sendHerdrShortcut(shortcut);
        case HerdrCdToPick():
          multiplexerKeyRows.onOpenRecentDirectories?.call();
        case HerdrPanePick(:final entry):
          final switched =
              runner != null &&
              await HerdrNavigator.focus(runner, entry, session: herdrSession);
          if (!switched) {
            // No CLI route (older Herdr, security-key host): let Herdr's own
            // picker take over inside the session.
            sendHerdrShortcut(HerdrShortcut.gotoPicker);
            _snack("Could not switch directly; opened Herdr's goto picker.");
          } else {
            focusTerminalAfterMultiplexer();
          }
      }
    } finally {
      unawaited(runner?.close());
    }
  }

  /// Opens a pane, tab or workspace in the focused pane's directory with
  /// the Herdr CLI; falls back to the machine's key binding for it. Uses
  /// [runner] when given (the navigator's), else opens its own.
  Future<void> createHerdrPane(
    HerdrNewPane kind, {
    AgentCommandRunner? runner,
  }) async {
    final own = runner == null ? _openRunner(_session.host) : null;
    final channel = runner ?? own;
    try {
      final created =
          channel != null &&
          await HerdrRemoteControl.createPaneOn(
            channel,
            kind,
            HerdrCommands(_herdrSession),
          );
      if (!mounted) {
        return;
      }
      if (created) {
        focusTerminalAfterMultiplexer();
      } else {
        sendHerdrShortcut(kind.shortcut);
      }
    } finally {
      unawaited(own?.close());
    }
  }

  /// Types [shortcut] with the machine's Herdr binding for it.
  void sendHerdrShortcut(HerdrShortcut shortcut) {
    final sent = sendHerdrAction(
      _session,
      shortcut.action,
      hostPrefix: _prefix,
    );
    if (!sent) {
      _snack(
        "${shortcut.label} has no key binding in this machine's Herdr "
        'config.',
      );
    } else if (shortcut.entersScrollMode) {
      multiplexerKeyRows.onEnterTmuxScrollMode();
    }
    focusTerminalAfterMultiplexer();
  }

  Future<bool> _confirm(String label, Object action) async {
    if (!mounted) {
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label?'),
        content: Text(switch (action) {
          HerdrShortcut.closePane || TmuxQuickAction.killPane =>
            'The focused pane and whatever runs in it will be closed.',
          HerdrShortcut.closeTab =>
            'The focused tab and all of its panes will be closed.',
          _ => 'The focused workspace and everything in it will be closed.',
        }),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('herdr-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(label),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  // ----------------------------------------------------------------- tmux

  Future<void> openTmuxNavigator() async {
    final host = _session.host;
    final reason = multiplexerUnavailableReason(host);
    final runner = _openRunner(host);
    final sessionName = tmuxSessionNameOf(host);
    final cache = TmuxListingCache.instance;
    TmuxSnapshot? snapshot;
    final cached = cache[host.id];
    if (cached is TmuxPanesAvailable) {
      snapshot = cached.snapshot;
    }
    try {
      final pick = await showTmuxNavigatorSheet(
        context: context,
        palette: _mxPalette,
        brightness: _mxBrightness,
        hostPrefix: _prefix,
        sessionName: sessionName,
        cached: cached,
        paneListUnavailableReason: reason,
        showCdTo: multiplexerKeyRows.onOpenRecentDirectories != null,
        load: runner == null
            ? null
            : () async {
                final listing = await TmuxNavigator.load(runner);
                if (listing is TmuxPanesAvailable) {
                  snapshot = listing.snapshot;
                }
                if (listing is! TmuxListingFailed) {
                  cache[host.id] = listing;
                }
                return listing;
              },
      );
      // The client and pane the sheet showed as current; resolved again
      // by the CLI when the list never loaded.
      final target = snapshot?.targetFor(sessionName);
      switch (pick) {
        case null:
          focusTerminalAfterMultiplexer();
        case TmuxActionPick(:final action):
          await runTmuxAction(action, runner: runner, target: target);
        case TmuxWindowPick(:final index):
          final switched =
              runner != null &&
              await TmuxNavigator.selectWindow(
                runner,
                index,
                target: target,
                sessionName: sessionName,
              );
          if (!switched) {
            _sendTmuxKey('$index');
          }
          focusTerminalAfterMultiplexer();
        case TmuxPanePick(:final pane):
          final switched =
              runner != null &&
              await TmuxNavigator.focus(runner, pane, target: target);
          if (!switched) {
            // tmux's own tree picker, inside the session.
            _sendTmuxKey('w');
            _snack("Could not switch directly; opened tmux's window tree.");
          }
          focusTerminalAfterMultiplexer();
        case TmuxCdToPick():
          multiplexerKeyRows.onOpenRecentDirectories?.call();
      }
    } finally {
      unawaited(runner?.close());
    }
  }

  /// Runs [action] through the tmux CLI at the app's client ([target], or
  /// resolved now); falls back to tmux's default key after the prefix.
  Future<void> runTmuxAction(
    TmuxQuickAction action, {
    AgentCommandRunner? runner,
    TmuxTarget? target,
  }) async {
    if (action.confirm && !await _confirm(action.label, action)) {
      focusTerminalAfterMultiplexer();
      return;
    }
    final own = runner == null ? _openRunner(_session.host) : null;
    final channel = runner ?? own;
    try {
      final done =
          channel != null &&
          await TmuxNavigator.perform(
            channel,
            action,
            target: target,
            sessionName: tmuxSessionNameOf(_session.host),
          );
      if (!mounted) {
        return;
      }
      if (!done) {
        _sendTmuxKey(action.fallbackKey);
      }
      focusTerminalAfterMultiplexer();
    } finally {
      unawaited(own?.close());
    }
  }

  void _sendTmuxKey(String key) {
    _session.sendPrefix(_prefix);
    _session.sendText(key);
  }

  // ------------------------------------------------------------ long-press

  /// The "new pane" menu, anchored on the button in [buttonContext].
  Future<void> openMultiplexerQuickMenu(BuildContext buttonContext) async {
    unawaited(HapticFeedback.mediumImpact());
    final box = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(buttonContext).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) {
      return;
    }
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromRect(
      topLeft & box.size,
      Offset.zero & overlay.size,
    );
    final multiplexer = pillMultiplexer;
    final entries = <(MultiplexerQuickPick, String, IconData, String)>[
      if (multiplexer == PillMultiplexer.herdr)
        for (final kind in HerdrNewPane.values)
          (HerdrQuickPick(kind), kind.label, kind.icon, 'herdr-${kind.name}')
      else
        for (final action in TmuxQuickActionDetails.creating)
          (
            TmuxQuickPick(action),
            action.label,
            action.icon,
            'tmux-${action.name}',
          ),
    ];
    final pick = await showMenu<MultiplexerQuickPick>(
      context: context,
      position: position,
      color: _mxPalette.panelFor(_mxBrightness),
      items: [
        for (final (value, label, icon, key) in entries)
          PopupMenuItem(
            key: ValueKey('pill-quick-$key'),
            value: value,
            child: Row(
              children: [
                Icon(icon, size: 18, color: _mxPalette.accent),
                const SizedBox(width: 10),
                Text(label),
              ],
            ),
          ),
      ],
    );
    switch (pick) {
      case null:
        focusTerminalAfterMultiplexer();
      case HerdrQuickPick(:final kind):
        await createHerdrPane(kind);
      case TmuxQuickPick(:final action):
        await runTmuxAction(action);
    }
  }
}
