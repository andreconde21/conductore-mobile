import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';

/// One row of the Herdr pane switcher: an agent pane, or a tab with no
/// agent in it (a plain shell), located as workspace › tab › pane.
class HerdrPaneEntry {
  const HerdrPaneEntry({
    required this.workspaceId,
    required this.workspaceLabel,
    required this.tabId,
    required this.tabLabel,
    required this.title,
    this.paneId,
    this.agentKind = '',
    this.status,
    this.focused = false,
  });

  final String workspaceId;
  final String workspaceLabel;

  /// Empty when Herdr did not report the agent's tab.
  final String tabId;
  final String tabLabel;

  /// Pane label: the agent's live name or terminal title, or the tab label
  /// for a tab without agents.
  final String title;

  /// Null for a tab entry.
  final String? paneId;

  /// Which agent runs in the pane (`claude`, `codex`, ...); empty for none.
  final String agentKind;

  /// Agent state; null for a tab without agents.
  final AgentAttentionState? status;

  /// Whether this is where Herdr's focus currently is.
  final bool focused;

  bool get isAgent => paneId != null;

  /// `workspace › tab › title`, skipping empty or repeated parts.
  String get path {
    final parts = <String>[workspaceLabel];
    if (tabLabel.isNotEmpty && tabLabel != workspaceLabel) {
      parts.add(tabLabel);
    }
    if (title.isNotEmpty && title != parts.last) {
      parts.add(title);
    }
    return parts.join(' › ');
  }

  @override
  bool operator ==(Object other) =>
      other is HerdrPaneEntry &&
      other.workspaceId == workspaceId &&
      other.workspaceLabel == workspaceLabel &&
      other.tabId == tabId &&
      other.tabLabel == tabLabel &&
      other.title == title &&
      other.paneId == paneId &&
      other.agentKind == agentKind &&
      other.status == status &&
      other.focused == focused;

  @override
  int get hashCode => Object.hash(
    workspaceId,
    workspaceLabel,
    tabId,
    tabLabel,
    title,
    paneId,
    agentKind,
    status,
    focused,
  );

  @override
  String toString() => 'HerdrPaneEntry($path)';
}

/// Outcome of listing a host's Herdr panes.
sealed class HerdrPaneListing {
  const HerdrPaneListing();
}

class HerdrPanesAvailable extends HerdrPaneListing {
  const HerdrPanesAvailable(this.entries);

  final List<HerdrPaneEntry> entries;
}

/// Herdr is not installed, or not on the PATH of a non-interactive shell.
class HerdrNotFound extends HerdrPaneListing {
  const HerdrNotFound();
}

/// Herdr is installed but its server is not running.
class HerdrNotRunning extends HerdrPaneListing {
  const HerdrNotRunning();
}

class HerdrListingFailed extends HerdrPaneListing {
  const HerdrListingFailed(this.message);

  final String message;
}

/// Lists Herdr panes and switches between them over a non-interactive
/// command runner, never through the terminal the user is typing in.
///
/// Uses the same commands as the connect picker (`herdr workspace list`,
/// `herdr tab list`) and the agent dashboard (`herdr agent list`).
abstract final class HerdrNavigator {
  static const _timeout = Duration(seconds: 10);

  static final agentListCommand = HerdrAttentionProvider.remoteCommand(
    'agent list',
  );

  /// `herdr agent focus <pane_id>`: jumps to that pane, switching workspace
  /// and tab as needed.
  static String paneFocusCommand(String paneId) =>
      HerdrAttentionProvider.remoteCommand('agent focus ${_quote(paneId)}');

  /// `herdr tab focus <tab_id>`.
  static String tabFocusCommand(String tabId) =>
      HerdrAttentionProvider.remoteCommand('tab focus ${_quote(tabId)}');

  /// Lists the panes of the Herdr server [session] (empty: the default
  /// session).
  static Future<HerdrPaneListing> load(
    AgentCommandRunner runner, {
    String session = '',
  }) async {
    try {
      final workspacesResult = await runner.run(
        RemoteSessionListing.herdrWorkspaceListFor(session),
        timeout: _timeout,
      );
      final workspaces = RemoteSessionListing.interpretHerdrWorkspaces(
        workspacesResult,
      );
      final List<HerdrWorkspaceInfo> workspaceItems;
      switch (workspaces) {
        case RemoteListingNotInstalled():
          return const HerdrNotFound();
        case RemoteListingNotRunning():
          return const HerdrNotRunning();
        case RemoteListingFailed(:final message):
          return HerdrListingFailed(message);
        case RemoteListingAvailable(:final items):
          workspaceItems = items;
      }

      var tabs = const <HerdrTabInfo>[];
      final tabsResult = await runner.run(
        RemoteSessionListing.herdrTabListFor(session),
        timeout: _timeout,
      );
      if (tabsResult.exitCode == null || tabsResult.exitCode == 0) {
        try {
          tabs = RemoteSessionListing.parseHerdrTabs(tabsResult.stdout);
        } on FormatException {
          // Tabs only add labels; the workspaces are still worth showing.
        }
      }

      var agents = const <AgentInfo>[];
      final agentsResult = await runner.run(
        HerdrCommands(session).agentList,
        timeout: _timeout,
      );
      if (agentsResult.exitCode == null || agentsResult.exitCode == 0) {
        try {
          agents = HerdrAttentionProvider.parseAgentList(agentsResult.stdout);
        } on AppFailure {
          // An older Herdr without `agent list`: list tabs only.
        }
      }
      return HerdrPanesAvailable(buildEntries(workspaceItems, tabs, agents));
    } on AppFailure catch (failure) {
      return HerdrListingFailed(failure.message);
    }
  }

  /// Orders rows by workspace, then tab number, then agent: each agent pane
  /// is a row, and a tab without agents is a row of its own.
  static List<HerdrPaneEntry> buildEntries(
    List<HerdrWorkspaceInfo> workspaces,
    List<HerdrTabInfo> tabs,
    List<AgentInfo> agents,
  ) {
    final entries = <HerdrPaneEntry>[];
    final placedAgents = <AgentInfo>{};
    for (final workspace in workspaces) {
      final workspaceTabs =
          tabs.where((tab) => tab.workspaceId == workspace.id).toList()
            ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));
      for (final tab in workspaceTabs) {
        final tabLabel = _tabLabel(tab);
        final focused =
            workspace.focused &&
            (tab.focused || workspace.activeTabId == tab.id);
        final tabAgents = agents.where((agent) => agent.tab == tab.id).toList();
        if (tabAgents.isEmpty) {
          entries.add(
            HerdrPaneEntry(
              workspaceId: workspace.id,
              workspaceLabel: workspace.label,
              tabId: tab.id,
              tabLabel: tabLabel,
              title: tabLabel,
              focused: focused,
            ),
          );
          continue;
        }
        for (final agent in tabAgents) {
          placedAgents.add(agent);
          entries.add(
            _agentEntry(
              agent,
              workspace: workspace,
              tabId: tab.id,
              tabLabel: tabLabel,
              focused: focused,
            ),
          );
        }
      }
      // Agents whose tab was not listed (older Herdr, or a race with a tab
      // being created) still belong to their workspace.
      for (final agent in agents) {
        if (agent.workspace == workspace.id && !placedAgents.contains(agent)) {
          placedAgents.add(agent);
          entries.add(
            _agentEntry(
              agent,
              workspace: workspace,
              tabId: agent.tab ?? '',
              tabLabel: '',
              focused: false,
            ),
          );
        }
      }
      if (workspaceTabs.isEmpty &&
          !agents.any((agent) => agent.workspace == workspace.id)) {
        entries.add(
          HerdrPaneEntry(
            workspaceId: workspace.id,
            workspaceLabel: workspace.label,
            tabId: workspace.activeTabId,
            tabLabel: '',
            title: '',
            focused: workspace.focused,
          ),
        );
      }
    }
    return entries;
  }

  static HerdrPaneEntry _agentEntry(
    AgentInfo agent, {
    required HerdrWorkspaceInfo workspace,
    required String tabId,
    required String tabLabel,
    required bool focused,
  }) {
    return HerdrPaneEntry(
      workspaceId: workspace.id,
      workspaceLabel: workspace.label,
      tabId: tabId,
      tabLabel: tabLabel,
      title: agent.name,
      paneId: agent.pane ?? agent.id,
      agentKind: agent.kind,
      status: agent.state,
      focused: focused,
    );
  }

  static String _tabLabel(HerdrTabInfo tab) {
    if (tab.label.isNotEmpty) {
      return tab.label;
    }
    final number = tab.number;
    // Never Herdr's id: "Tab 3", or just "Tab".
    return number == null ? 'Tab' : 'Tab $number';
  }

  /// Switches Herdr to [entry]. Returns false when the CLI could not do it
  /// (an older Herdr, or the pane is gone), so the caller can fall back to
  /// the prefix bindings.
  static Future<bool> focus(
    AgentCommandRunner runner,
    HerdrPaneEntry entry, {
    String session = '',
  }) async {
    final paneId = entry.paneId;
    final commands = HerdrCommands(session);
    final String command;
    if (paneId != null && paneId.isNotEmpty) {
      command = commands.agentFocus(paneId);
    } else if (entry.tabId.isNotEmpty) {
      command = commands.tabFocus(entry.tabId);
    } else {
      return false;
    }
    try {
      final result = await runner.run(command, timeout: _timeout);
      return result.exitCode == null || result.exitCode == 0;
    } on AppFailure {
      return false;
    }
  }

  static String _quote(String value) => shellQuoteArgument(value);
}

/// Last pane listing per host, so the navigator opens with something to
/// show while it refreshes.
class HerdrPaneListingCache {
  HerdrPaneListingCache._();

  static final instance = HerdrPaneListingCache._();

  final _listings = <String, HerdrPaneListing>{};

  HerdrPaneListing? operator [](String hostId) => _listings[hostId];

  void operator []=(String hostId, HerdrPaneListing listing) {
    _listings[hostId] = listing;
  }

  void clear() => _listings.clear();
}
