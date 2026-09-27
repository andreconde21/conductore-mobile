import 'package:conduit/features/voice_guide/domain/guide_world.dart';

/// Moves the app where the guide was asked to go. Platform-neutral: the
/// app implements it over its navigator and connect flow.
abstract class GuideNavigator {
  /// What is on screen now.
  GuideScreen get screen;

  Future<void> home();

  /// Shows [agent]: in Chat View ([GuideView.chat]), its terminal
  /// ([GuideView.terminal]), or the view its session opens in (null).
  /// Returns the view shown, or null when nothing could be opened.
  Future<GuideView?> openAgent(GuideAgent agent, {GuideView? view});

  /// Shows [machine]'s session, connecting if needed. False when the user
  /// has to pick a session on screen first.
  Future<bool> openMachine(GuideMachine machine);
}

/// Types a prompt into an agent's session (the companion's `send`).
abstract class GuideMessenger {
  Future<void> send(GuideAgent agent, String text);
}

/// Spoken usage: the Claude limits, or null when nothing is known.
typedef GuideUsageText = String? Function(String languageCode);

/// Spoken catch-up: the agents dashboard's counts and its Needs you and
/// Stuck agents, briefly (fetched fresh; summaries when they are on).
typedef GuideCatchUpText = Future<String> Function(String languageCode);

/// One Claude account (cswap) across machines, as the guide names it.
class GuideAccount {
  const GuideAccount({
    required this.label,
    this.active = false,
    this.targets = const [],
  });

  /// Alias or masked email, as the companion reports it.
  final String label;

  /// New Claude sessions use it on some machine already.
  final bool active;

  /// Machines where it can be made the active account.
  final List<({String hostId, String hostName, int slot})> targets;
}

/// What switching did on one machine.
typedef GuideAccountSwitch = ({String hostName, bool ok, String? error});

/// Claude account switching (the companion's `cswap-switch`), where a
/// machine reports cswap.
abstract class GuideAccounts {
  /// Some machine can switch accounts.
  bool get available;

  List<GuideAccount> get accounts;

  /// Makes [account] the one new Claude sessions use on every machine in
  /// its targets.
  Future<List<GuideAccountSwitch>> switchTo(GuideAccount account);
}

/// The turn "undo that" would roll back, from a dry run.
class GuideTurnPreview {
  const GuideTurnPreview({
    required this.turn,
    required this.files,
    this.prompt = '',
  });

  final int turn;

  /// Files the undo would restore or delete.
  final int files;

  /// The turn's prompt (its first line).
  final String prompt;
}

/// Review mode and "Undo this turn" (the companion's turn snapshots).
abstract class GuideReviewer {
  /// Review can open for [agent] (its turn, or on an older companion the
  /// working tree's diff).
  bool canReview(GuideAgent agent);

  /// [agent]'s machine snapshots its turns, so one can be undone.
  bool canUndo(GuideAgent agent);

  /// Opens Review of [agent]'s last turn; false when it could not open.
  Future<bool> review(GuideAgent agent);

  /// The newest turn of [agent] an undo would restore, or null when it
  /// has none. Throws (an AppFailure) with the companion's reason when the
  /// agent is working or HEAD moved.
  Future<GuideTurnPreview?> lastTurn(GuideAgent agent);

  /// Undoes [turn]: the number of files restored. The state before is
  /// saved, so Review's Redo can put it back.
  Future<int> undo(GuideAgent agent, int turn);
}
