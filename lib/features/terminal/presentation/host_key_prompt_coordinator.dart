import 'dart:async';
import 'dart:collection';

import 'package:conduit/features/terminal/domain/host_key_mismatches.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:flutter/foundation.dart';

class HostKeyPromptCoordinator extends ChangeNotifier implements HostKeyPrompt {
  final Queue<_PendingPrompt> _queue = Queue<_PendingPrompt>();

  /// Changed keys that background work refused without asking; the home
  /// page shows them on their machines for an explicit review. The app
  /// hands the same store to its `SecureHostKeyVerifier`.
  final HostKeyMismatches mismatches = HostKeyMismatches();

  HostKeyPromptRequest? get current =>
      _queue.isEmpty ? null : _queue.first.request;

  @override
  Future<HostKeyDecision> request(HostKeyPromptRequest request) {
    final completer = Completer<HostKeyDecision>();
    _queue.add(_PendingPrompt(request, completer));
    notifyListeners();
    return completer.future;
  }

  void resolve(HostKeyPromptRequest request, HostKeyDecision decision) {
    if (_queue.isEmpty || _queue.first.request != request) {
      return;
    }
    final pending = _queue.removeFirst();
    pending.completer.complete(decision);
    notifyListeners();
  }

  void rejectAll() {
    if (_queue.isEmpty) {
      return;
    }
    while (_queue.isNotEmpty) {
      _queue.removeFirst().completer.complete(HostKeyDecision.reject);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    rejectAll();
    super.dispose();
  }
}

class _PendingPrompt {
  const _PendingPrompt(this.request, this.completer);

  final HostKeyPromptRequest request;
  final Completer<HostKeyDecision> completer;
}
