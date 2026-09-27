import 'dart:async';

import 'package:conduit/features/desktop_shell/data/desktop_shell_store.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_prefs.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/domain/unread_tracker.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:flutter/foundation.dart';

/// The optional panel on the right of the main area.
enum ShellRightPanel {
  none,

  /// The agent inbox with approvals.
  agents,

  /// The web live preview of the focused session.
  preview,

  /// The usage breakdown (limits, tokens, cost), from the usage summary.
  usage,
}

/// State of the desktop shell: the sidebar (width, collapsed, the user's
/// arrangement), the main area's split layout, the right panel and the
/// unread markers. Persisted per device through a [DesktopShellStore].
///
/// Three listenables keep rebuilds narrow: this controller for the chrome
/// and the sidebar arrangement, [layout] for the panes (the terminal page
/// listens to it), and [unreadChanges] for the markers.
class DesktopShellController extends ChangeNotifier {
  DesktopShellController({
    DesktopShellStore? store,
    this.saveDelay = const Duration(milliseconds: 800),
    DateTime Function()? clock,
  }) : _store = store ?? InMemoryDesktopShellStore(),
       _clock = clock ?? DateTime.now,
       unread = UnreadTracker(clock: clock);

  final DateTime Function() _clock;

  /// The shell's clock (tests move it).
  DateTime now() => _clock();

  final DesktopShellStore _store;
  final Duration saveDelay;

  /// Unread markers; change them through this controller so listeners
  /// hear about it.
  final UnreadTracker unread;

  static const minSidebarWidth = 220.0;
  static const maxSidebarWidth = 420.0;
  static const defaultSidebarWidth = 280.0;

  /// Width of the collapsed sidebar (icons only).
  static const collapsedSidebarWidth = 56.0;

  static const minRightPanelWidth = 280.0;
  static const maxRightPanelWidth = 560.0;

  double _sidebarWidth = defaultSidebarWidth;
  bool _sidebarCollapsed = false;
  ShellRightPanel _rightPanel = ShellRightPanel.none;
  double _rightPanelWidth = 360;
  SidebarPrefs _prefs = const SidebarPrefs();
  bool _showHome = false;
  bool _showUsage = false;
  String? _usageDay;
  String _filter = '';
  bool _layoutHeld = true;
  bool _loaded = false;
  bool _disposed = false;
  Timer? _saveTimer;
  Completer<void>? _loading;

  /// The panes, as saved; render them through [ShellLayout.pruned] with
  /// the views that exist.
  final ValueNotifier<ShellLayout> layout = ValueNotifier(ShellLayout.single());

  /// Fires when unread markers change.
  Listenable get unreadChanges => _unreadSignal;
  final _unreadSignal = _Signal();

  final Map<String, Map<String, List<TmuxWindowInfo>>> _tmuxWindows = {};
  final Set<String> _tmuxLoading = {};

  double get sidebarWidth => _sidebarWidth;
  bool get sidebarCollapsed => _sidebarCollapsed;
  ShellRightPanel get rightPanel => _rightPanel;
  double get rightPanelWidth => _rightPanelWidth;

  /// The sidebar prefs, with [machineAlias] applied.
  SidebarPrefs get prefs {
    final alias = machineAlias;
    if (alias == null) return _prefs;
    final cached = _aliased;
    if (cached != null &&
        identical(cached.source, _prefs) &&
        cached.alias == alias) {
      return cached.prefs;
    }
    final aliased = _prefs.withMachineAlias(alias.from, alias.to);
    _aliased = (source: _prefs, alias: alias, prefs: aliased);
    return aliased;
  }

  ({SidebarPrefs source, ({String from, String to}) alias, SidebarPrefs prefs})?
  _aliased;

  /// A saved machine (`from`) the sidebar shows as another (`to`): the
  /// synced machine that is this device, as "This computer". Its pins,
  /// group and order carry over ([SidebarPrefs.withMachineAlias]); the
  /// first edit saves them under `to`. Set by the page as it builds the
  /// tree, so setting it notifies nobody.
  ({String from, String to})? machineAlias;

  bool get loaded => _loaded;

  /// The dashboard is on screen although views are open ("Home").
  bool get showHome => _showHome;

  /// The usage explorer fills the main area (not saved).
  bool get showUsage => _showUsage;

  /// The day the explorer opened at (the Usage tab's chart), once.
  String? get usageDay => _usageDay;

  /// The sidebar's filter text (not saved).
  String get filter => _filter;

  /// Whether the saved layout waits for the restored sessions: until
  /// [releaseLayout], the terminal page renders it pruned but does not
  /// rewrite it, so panes of sessions that are still coming back survive.
  bool get layoutHeld => _layoutHeld;

  /// Reads the saved state once.
  Future<void> load() {
    final loading = _loading;
    if (loading != null) return loading.future;
    final completer = _loading = Completer<void>();
    unawaited(() async {
      try {
        final json = await _store.load();
        if (_disposed) return;
        if (json != null) _apply(json);
      } finally {
        _loaded = true;
        if (!_disposed) {
          notifyListeners();
          _unreadSignal.notify();
        }
        completer.complete();
      }
    }());
    return completer.future;
  }

  void _apply(Map<String, Object?> json) {
    final width = json['sidebarWidth'];
    if (width is num) _sidebarWidth = _clampSidebar(width.toDouble());
    _sidebarCollapsed = json['sidebarCollapsed'] == true;
    final panel = json['rightPanel'];
    _rightPanel =
        ShellRightPanel.values
            .where((value) => value.name == panel)
            .firstOrNull ??
        ShellRightPanel.none;
    final panelWidth = json['rightPanelWidth'];
    if (panelWidth is num) {
      _rightPanelWidth = _clampRightPanel(panelWidth.toDouble());
    }
    _prefs = SidebarPrefs.fromJson(json['sidebar']);
    layout.value = ShellLayout.fromJson(json['layout']);
    unread.load(json['unread']);
  }

  Map<String, Object?> toJson() => {
    'sidebarWidth': _sidebarWidth,
    'sidebarCollapsed': _sidebarCollapsed,
    'rightPanel': _rightPanel.name,
    'rightPanelWidth': _rightPanelWidth,
    'sidebar': _prefs.toJson(),
    'layout': layout.value.toJson(),
    'unread': unread.toJson(),
  };

  static double _clampSidebar(double width) =>
      width.clamp(minSidebarWidth, maxSidebarWidth);

  static double _clampRightPanel(double width) =>
      width.clamp(minRightPanelWidth, maxRightPanelWidth);

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    if (!_loaded || _disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  /// Writes pending changes now (the app goes to the background).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_loaded) return;
    await _store.save(toJson());
  }

  set sidebarWidth(double width) {
    final next = _clampSidebar(width);
    if (next == _sidebarWidth) return;
    _sidebarWidth = next;
    _changed();
  }

  set sidebarCollapsed(bool collapsed) {
    if (collapsed == _sidebarCollapsed) return;
    _sidebarCollapsed = collapsed;
    _changed();
  }

  void toggleSidebar() => sidebarCollapsed = !_sidebarCollapsed;

  set rightPanel(ShellRightPanel panel) {
    if (panel == _rightPanel) return;
    _rightPanel = panel;
    _changed();
  }

  /// Opens [panel], or closes it when it is the one open.
  void toggleRightPanel(ShellRightPanel panel) =>
      rightPanel = _rightPanel == panel ? ShellRightPanel.none : panel;

  set rightPanelWidth(double width) {
    final next = _clampRightPanel(width);
    if (next == _rightPanelWidth) return;
    _rightPanelWidth = next;
    _changed();
  }

  /// Showing home or a terminal also leaves the usage explorer.
  set showHome(bool value) {
    if ((value == _showHome && !_showUsage) || _disposed) return;
    _showHome = value;
    _showUsage = false;
    notifyListeners();
  }

  /// Opens the usage explorer in the main area (at [day]), or closes it.
  void setShowUsage(bool value, {String? day}) {
    if (_disposed || (value == _showUsage && day == _usageDay)) return;
    _showUsage = value;
    _usageDay = value ? day : null;
    notifyListeners();
  }

  set filter(String value) {
    if (value == _filter || _disposed) return;
    _filter = value;
    notifyListeners();
  }

  void updatePrefs(SidebarPrefs Function(SidebarPrefs prefs) edit) {
    final next = edit(prefs);
    if (next == _prefs) return;
    _prefs = next;
    _changed();
  }

  void toggleExpanded(SidebarNode node) => updatePrefs(
    (prefs) => prefs.setExpanded(
      node.key,
      !prefs.isExpanded(node.key, byDefault: node.expandedByDefault),
    ),
  );

  bool isExpanded(SidebarNode node) =>
      prefs.isExpanded(node.key, byDefault: node.expandedByDefault);

  /// Applies [edit] to the layout as rendered with [views] (panes of views
  /// that are gone are dropped first) and saves it.
  void editLayout(
    Set<String> views,
    ShellLayout Function(ShellLayout layout) edit,
  ) {
    final next = edit(layout.value.pruned(views));
    if (next == layout.value) return;
    layout.value = next;
    _scheduleSave();
  }

  /// Lets the terminal page rewrite the layout (restored sessions are back).
  void releaseLayout() {
    if (!_layoutHeld) return;
    _layoutHeld = false;
    notifyListeners();
  }

  // Unread markers.

  void _unreadChanged(bool changed) {
    if (!changed || _disposed) return;
    _unreadSignal.notify();
    _scheduleSave();
  }

  /// Runs several unread updates, notifying once.
  void updateUnread(bool Function(UnreadTracker tracker) body) =>
      _unreadChanged(body(unread));

  void markRead(String key) => _unreadChanged(unread.markRead(key));

  void markUnread(String key) => _unreadChanged(unread.markUnread(key));

  /// The rows on screen (see [UnreadTracker.setViewed]).
  void setViewed(Set<String> prefixes) =>
      _unreadChanged(unread.setViewed(prefixes));

  /// How many unread rows [node] holds, itself included.
  int unreadCount(SidebarNode node, Set<String> unreadKeys) {
    var count = 0;
    for (final key in unreadKeys) {
      if (SidebarKeys.isUnder(key, node.key)) count += 1;
    }
    return count;
  }

  // tmux windows, listed when a session row is opened.

  List<TmuxWindowInfo>? tmuxWindowsFor(String machineId, String session) =>
      _tmuxWindows[machineId]?[session];

  Map<String, List<TmuxWindowInfo>> tmuxWindowsOf(String machineId) =>
      _tmuxWindows[machineId] ?? const {};

  /// Lists [session]'s windows through [fetch] (once at a time).
  Future<void> loadTmuxWindows(
    String machineId,
    String session,
    Future<List<TmuxWindowInfo>> Function() fetch,
  ) async {
    final key = '$machineId\n$session';
    if (!_tmuxLoading.add(key)) return;
    try {
      final windows = await fetch();
      if (_disposed) return;
      (_tmuxWindows[machineId] ??= {})[session] = windows;
      notifyListeners();
    } catch (_) {
      // The row stays closed-looking; opening it again retries.
    } finally {
      _tmuxLoading.remove(key);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_saveTimer != null && _loaded) unawaited(flush());
    _saveTimer?.cancel();
    layout.dispose();
    _unreadSignal.dispose();
    super.dispose();
  }
}

class _Signal extends ChangeNotifier {
  void notify() => notifyListeners();
}
