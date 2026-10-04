import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/terminal/domain/herdr_navigator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Herdr's and the companion's ids (`w1:t2`, `w1:p1`, session UUIDs) are
/// for commands only: every label a person reads is made from names,
/// titles, folders and numbers.
void main() {
  // Shaped like Herdr 0.9.1's `herdr pane list`.
  const paneList =
      '{"id":"cli:pane:list","result":{"panes":['
      '{"agent":"claude","agent_status":"idle","cwd":"/root/Projects/api",'
      '"focused":false,"pane_id":"w1:p1","tab_id":"w1:t1",'
      '"terminal_title_stripped":"Tasks PR review","workspace_id":"w1"},'
      '{"agent_status":"idle","cwd":"/root/Projects/api","focused":true,'
      '"foreground_cwd":"/root/Projects/api/web","pane_id":"w1:p2",'
      '"tab_id":"w1:t1","terminal_title":"","workspace_id":"w1"}]}}';

  test('a tab takes what its focused pane shows', () {
    final tabs = RemoteSessionListing.attachPanes([
      const HerdrTabInfo(id: 'w1:t1', workspaceId: 'w1', paneCount: 2),
      const HerdrTabInfo(id: 'w1:t9', workspaceId: 'w1', number: 9),
    ], paneList);
    // The focused pane has no title: its folder.
    expect(tabs.first.paneTitle, 'web');
    expect(tabs.first.summary, 'web · 2 panes');
    expect(tabs.first.displayLabel(1), 'Tab 1');
    expect(tabs.last.summary, '');
    expect(tabs.last.displayLabel(2), 'Tab 9');
    expect(RemoteSessionListing.attachPanes(tabs, 'not json'), same(tabs));
  });

  test('a Herdr agent without a title is its kind and folder', () {
    final agents = HerdrAttentionProvider.parseAgentList(
      '{"result":{"agents":['
      '{"agent":"claude","agent_status":"idle","cwd":"/root/Projects/api",'
      '"pane_id":"w1:p1","tab_id":"w1:t1","terminal_title":"",'
      '"workspace_id":"w1"},'
      '{"agent":"codex","agent_status":"working","pane_id":"w1:p2",'
      '"workspace_id":"w1"}]}}',
    );
    expect(agents.map((agent) => agent.name), ['claude in api', 'codex']);
    // The id still drives commands.
    expect(agents.first.pane, 'w1:p1');
  });

  test('a companion session without name or folder is not its UUID', () {
    final snapshot = ConductoreHostAttentionProvider.parseSnapshot(
      '{"version":1,"seq":1,"agents":[{"sessionId":'
      '"5a57ee59-db0f-4964-9590-21c324d8da54","state":"working",'
      '"pending":[]}]}',
    );
    expect(snapshot.agents.single.name, 'Claude Code session');
  });

  test('the navigator names an unlabelled tab by its number', () {
    const workspace = HerdrWorkspaceInfo(id: 'w1', label: 'api', tabCount: 2);
    final entries = HerdrNavigator.buildEntries(
      [workspace],
      const [
        HerdrTabInfo(id: 'w1:t1', workspaceId: 'w1', number: 1),
        HerdrTabInfo(id: 'w1:t2', workspaceId: 'w1'),
      ],
      const [],
    );
    final labels = [for (final entry in entries) entry.tabLabel];
    expect(labels, containsAll(['Tab 1', 'Tab']));
    expect(labels.any((label) => label.contains('w1:')), isFalse);
  });
}
