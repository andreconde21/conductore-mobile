import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';

/// Where the app is asked to go when launched from the widget or tile.
enum AgentStatusLaunchTarget {
  /// Open the agent attention sheet (widgets placed before the
  /// dashboard counts, until they redraw).
  agents,

  /// Open the agents dashboard (a tap on the widget, or on the tile).
  dashboard,

  /// Open Claude's usage (a tap on the widget's limit rings).
  usage,

  /// Start the voice guide (its quick-settings tile, the headset's
  /// voice-assistant button).
  guide,
}

/// Outcome of asking the system to add the quick-settings tile.
enum AddTileResult {
  added,
  alreadyAdded,
  declined,

  /// Android below 13, or a platform without the native side; the tile has
  /// to be added from the quick-settings edit panel by hand.
  unsupported,
  failed,
}

/// Bridge to the native home-screen widget and quick-settings tile.
///
/// Abstract so the pusher and launch handling can be tested with a fake.
abstract class AgentStatusWidgetChannel {
  /// Stores [snapshot] natively and refreshes every widget and the tile.
  Future<void> push(AgentStatusSnapshot snapshot);

  /// Returns and clears the pending launch target, if the app was opened
  /// (or brought back) from the widget or tile.
  Future<AgentStatusLaunchTarget?> consumeLaunchTarget();

  /// Called when a new launch target arrives while the app is running; the
  /// listener then calls [consumeLaunchTarget].
  void setLaunchTargetListener(void Function()? listener);

  Future<AddTileResult> requestAddTile();
}
