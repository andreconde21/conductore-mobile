import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:flutter/widgets.dart';

/// Makes the [TalkbawtController] reachable from every route (the chat
/// view's menu, the dashboard cards, Settings, shared links).
class TalkbawtScope extends InheritedNotifier<TalkbawtController> {
  const TalkbawtScope({
    required TalkbawtController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static TalkbawtController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TalkbawtScope>()?.notifier;
}
