import 'package:flutter/widgets.dart';

class KeyboardVisibilty extends StatefulWidget {
  const KeyboardVisibilty({
    super.key,
    required this.child,
    this.onKeyboardShow,
    this.onKeyboardHide,
  });

  final Widget child;

  final VoidCallback? onKeyboardShow;

  final VoidCallback? onKeyboardHide;

  @override
  KeyboardVisibiltyState createState() => KeyboardVisibiltyState();
}

class KeyboardVisibiltyState extends State<KeyboardVisibilty>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final bottomInset = View.of(context).viewInsets.bottom;

    // Every frame of the keyboard sliding in reports a larger inset; each
    // one is a show (the view shrank again). One sliding out is a hide only
    // once it is gone, so reading scrollback while it closes stays put.
    if (bottomInset > _lastBottomInset) {
      widget.onKeyboardShow?.call();
    } else if (bottomInset == 0 && _lastBottomInset > 0) {
      widget.onKeyboardHide?.call();
    }

    _lastBottomInset = bottomInset;

    super.didChangeMetrics();
  }

  var _lastBottomInset = 0.0;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
