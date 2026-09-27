import 'package:flutter/foundation.dart';

/// A screen the home page is asked to open from outside it.
enum HomeLaunchRequest {
  /// The agents dashboard.
  dashboard,

  /// Claude's usage.
  usage,
}

/// Hands launch requests (the home-screen widget's taps) to the home page,
/// which owns the dashboard's and usage's navigation. A request made
/// before the page listens waits until it [take]s it.
class HomeLaunchRequests extends ChangeNotifier {
  HomeLaunchRequest? _pending;

  void request(HomeLaunchRequest request) {
    _pending = request;
    notifyListeners();
  }

  /// The pending request, cleared.
  HomeLaunchRequest? take() {
    final pending = _pending;
    _pending = null;
    return pending;
  }
}
