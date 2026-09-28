import 'dart:async';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/share_target/domain/share_inbox.dart';
import 'package:conduit/features/share_target/domain/share_target_source.dart';
import 'package:conduit/features/share_target/domain/share_uploader.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/foundation.dart';

enum ShareTargetPhase {
  /// Nothing shared, or the last share has been delivered.
  idle,

  /// A share is parked until a session connects ("Shared content waiting").
  waitingForSession,

  /// More than one session is open; the user picks the target.
  choosingSession,

  /// Files are being copied to the chosen host.
  uploading,

  /// The upload failed; the share is kept for retry or discard.
  failed,
}

/// Takes a delivered draft for [hostId] straight into an open composer
/// (Chat View); false leaves it to the terminal page.
typedef ShareDraftReceiver = bool Function(String hostId, String draft);

/// Drives a shared payload from the Android share sheet into a session's
/// Chat composer.
///
/// The controller owns the decision logic (auto-pick a lone session, wait
/// for a connection, ask when several are open) and the resulting per-host
/// composer drafts; the widget layer (`ShareTargetHost` and `TerminalPage`)
/// renders pickers, progress and banners and consumes the drafts.
class ShareTargetController extends ChangeNotifier {
  ShareTargetController({
    required ShareTargetSource source,
    required TerminalWorkspaceController workspace,
    required ShareUploader uploader,
  }) : this._(source, workspace, uploader);

  ShareTargetController._(this._source, this._workspace, this._uploader) {
    _workspace.addListener(_handleWorkspaceChanged);
  }

  final ShareTargetSource _source;
  final TerminalWorkspaceController _workspace;
  final ShareUploader _uploader;

  StreamSubscription<SharedPayload>? _subscription;
  SharedPayload? _pending;
  ShareTargetPhase _phase = ShareTargetPhase.idle;
  String? _error;
  ShareUploadProgress? _progress;
  bool _gateOpen = true;
  int _attachedTerminalPages = 0;
  TerminalSessionController? _lastTarget;
  String? _readyHostId;
  final Map<String, String> _drafts = {};
  final List<ShareDraftReceiver> _receivers = [];
  bool _disposed = false;
  bool _canRetry = true;

  /// Bumped when an upload is cancelled, so its late result is ignored.
  int _attempt = 0;

  /// Takes a share before the upload flow sees it (a shared Talkbawt link
  /// opens its preview instead); true when it took it.
  bool Function(SharedPayload payload)? intercept;

  SharedPayload? get pending => _pending;
  ShareTargetPhase get phase => _phase;
  String? get error => _error;
  ShareUploadProgress? get progress => _progress;

  /// Whether [retry] can help after a failure: not when the shared file
  /// itself is gone from the phone.
  bool get canRetry => _canRetry;

  /// The machine the current (or failed) upload goes to.
  String? get targetName => _lastTarget?.host.name;

  /// Whether a terminal page is on screen to receive drafts.
  bool get terminalPageAttached => _attachedTerminalPages > 0;

  /// Begins listening for shares and drains any queued before startup.
  Future<void> start() async {
    _subscription ??= _source.shares.listen(receive);
    for (final payload in await _source.takePending()) {
      receive(payload);
    }
  }

  /// Accepts a payload. A share arriving while one is parked merges into it
  /// so nothing the user sent is lost.
  void receive(SharedPayload payload) {
    if (_disposed) {
      return;
    }
    if (payload.isEmpty) {
      if (payload.unreadable.isNotEmpty) _failUnreadable(payload.unreadable);
      return;
    }
    if (intercept?.call(payload) ?? false) return;
    final current = _pending;
    if (current != null && _phase != ShareTargetPhase.uploading) {
      _pending = SharedPayload(
        text: mergeShareDraft(current.text ?? '', payload.text ?? '').trim(),
        subject: current.subject ?? payload.subject,
        files: [...current.files, ...payload.files],
      );
      if (!_pending!.hasText) {
        _pending = SharedPayload(
          subject: _pending!.subject,
          files: _pending!.files,
        );
      }
    } else if (current != null) {
      // An upload is running; queue behind it by re-receiving afterwards.
      _queued.add(payload);
      return;
    } else {
      _pending = payload;
    }
    _error = null;
    _canRetry = true;
    if (_phase == ShareTargetPhase.failed ||
        _phase == ShareTargetPhase.choosingSession) {
      _phase = ShareTargetPhase.idle;
    }
    _evaluate();
  }

  final List<SharedPayload> _queued = [];

  /// Blocks delivery while the app is locked; reopening re-evaluates.
  void setGateOpen(bool open) {
    if (_gateOpen == open) {
      return;
    }
    _gateOpen = open;
    _evaluate();
  }

  void attachTerminalPage() {
    _attachedTerminalPages += 1;
  }

  void detachTerminalPage() {
    if (_attachedTerminalPages > 0) {
      _attachedTerminalPages -= 1;
    }
  }

  /// Registers an open composer that takes delivered drafts for its own
  /// host; the latest registered is asked first.
  void addDraftReceiver(ShareDraftReceiver receiver) =>
      _receivers.add(receiver);

  void removeDraftReceiver(ShareDraftReceiver receiver) =>
      _receivers.remove(receiver);

  /// Uploads the pending files (if any) to [session]'s host and hands the
  /// composer draft to an open Chat View of that host, else stores it for
  /// the terminal page.
  Future<void> deliverTo(TerminalSessionController session) async {
    final payload = _pending;
    if (payload == null || _phase == ShareTargetPhase.uploading) {
      return;
    }
    final attempt = ++_attempt;
    _lastTarget = session;
    _phase = ShareTargetPhase.uploading;
    _error = null;
    _canRetry = true;
    _progress = null;
    notifyListeners();
    List<String> remotePaths;
    try {
      remotePaths = await _uploader.upload(
        session.host,
        payload.files,
        onProgress: (progress) {
          if (_disposed || attempt != _attempt) return;
          _progress = progress;
          notifyListeners();
        },
      );
    } catch (error) {
      if (_disposed || attempt != _attempt) {
        return;
      }
      _phase = ShareTargetPhase.failed;
      _error = switch (error) {
        AppFailure() => error.userMessage,
        TimeoutException() =>
          '${session.host.name} did not answer in time. Check the '
              'connection and retry.',
        _ => 'Upload failed: $error',
      };
      _canRetry = error is! ShareFileUnavailable;
      _progress = null;
      notifyListeners();
      return;
    }
    if (_disposed || attempt != _attempt) {
      return;
    }
    final hostId = session.host.id;
    final draft = buildShareDraft(text: payload.text, remotePaths: remotePaths);
    _pending = null;
    _progress = null;
    _phase = ShareTargetPhase.idle;
    if (_workspace.sessions.contains(session)) {
      _workspace.activate(session);
    }
    if (!_offerToReceivers(hostId, draft)) {
      _drafts[hostId] = mergeShareDraft(_drafts[hostId] ?? '', draft);
      _readyHostId = hostId;
    }
    notifyListeners();
    _drainQueue();
  }

  bool _offerToReceivers(String hostId, String draft) {
    for (final receiver in _receivers.reversed.toList()) {
      if (receiver(hostId, draft)) return true;
    }
    return false;
  }

  /// Gives up on the running upload (the progress dialog's Cancel): the
  /// share is kept, failed, for Retry or Discard. A late result of the
  /// abandoned upload is ignored.
  void cancel() {
    if (_phase != ShareTargetPhase.uploading) {
      return;
    }
    _attempt += 1;
    _phase = ShareTargetPhase.failed;
    _error = 'The upload was cancelled.';
    _canRetry = true;
    _progress = null;
    notifyListeners();
  }

  /// Nothing of a share could be read on arrival: say so rather than
  /// dropping it silently. Only Discard is offered.
  void _failUnreadable(List<String> names) {
    if (_phase == ShareTargetPhase.uploading || _pending != null) {
      return;
    }
    _pending = const SharedPayload();
    _phase = ShareTargetPhase.failed;
    _canRetry = false;
    _error = names.length == 1
        ? 'Could not read ${names.single} from the app that shared it. '
              'Share it again.'
        : 'Could not read the ${names.length} shared files from the app '
              'that shared them. Share them again.';
    notifyListeners();
  }

  /// Retries the failed delivery against the same session when it is still
  /// open; otherwise re-runs session selection.
  Future<void> retry() async {
    if (_phase != ShareTargetPhase.failed || !_canRetry) {
      return;
    }
    final target = _lastTarget;
    if (target != null && _workspace.sessions.contains(target)) {
      await deliverTo(target);
      return;
    }
    _phase = ShareTargetPhase.idle;
    _evaluate();
  }

  /// Drops the share and its cached files.
  void discard() {
    final payload = _pending;
    _pending = null;
    _phase = ShareTargetPhase.idle;
    _error = null;
    _canRetry = true;
    _progress = null;
    notifyListeners();
    if (payload != null) {
      unawaited(_deleteCache(payload));
    }
    _drainQueue();
  }

  /// A draft delivered for [hostId], removed on read so it is inserted only
  /// once.
  String? takeDraft(String hostId) => _drafts.remove(hostId);

  bool hasDraft(String hostId) => _drafts.containsKey(hostId);

  /// The host whose draft was just stored; cleared on read. The widget layer
  /// uses it to bring the terminal page forward.
  String? takeReadyHostId() {
    final id = _readyHostId;
    _readyHostId = null;
    return id;
  }

  void _drainQueue() {
    if (_queued.isEmpty) {
      return;
    }
    final next = List<SharedPayload>.from(_queued);
    _queued.clear();
    next.forEach(receive);
  }

  void _handleWorkspaceChanged() {
    if (_phase == ShareTargetPhase.waitingForSession ||
        (_phase == ShareTargetPhase.choosingSession &&
            _workspace.sessions.isEmpty)) {
      _evaluate();
    }
  }

  void _evaluate() {
    if (_disposed) {
      return;
    }
    if (_pending == null) {
      _setPhase(ShareTargetPhase.idle);
      return;
    }
    if (_phase == ShareTargetPhase.uploading ||
        _phase == ShareTargetPhase.failed) {
      return;
    }
    if (!_gateOpen) {
      _setPhase(ShareTargetPhase.waitingForSession);
      return;
    }
    final sessions = _workspace.sessions;
    if (sessions.isEmpty) {
      _setPhase(ShareTargetPhase.waitingForSession);
      return;
    }
    // Files leave the phone: the user always confirms the machine they go
    // to, even with a single session open (another app chose what to
    // share).
    final confirm = _pending!.files.isNotEmpty;
    if (_phase == ShareTargetPhase.waitingForSession) {
      // Parked until something connects: deliver text to a lone connected
      // session, ask when several are up or files are to be confirmed,
      // keep waiting otherwise.
      final connected = sessions.where((s) => s.isConnected).toList();
      if (connected.length == 1 && !confirm) {
        unawaited(deliverTo(connected.first));
      } else if (connected.length > 1 || (connected.isNotEmpty && confirm)) {
        _setPhase(ShareTargetPhase.choosingSession);
      }
      return;
    }
    if (sessions.length == 1 && !confirm) {
      unawaited(deliverTo(sessions.first));
    } else {
      _setPhase(ShareTargetPhase.choosingSession);
    }
  }

  void _setPhase(ShareTargetPhase phase) {
    if (_phase == phase) {
      return;
    }
    _phase = phase;
    notifyListeners();
  }

  Future<void> _deleteCache(SharedPayload payload) async {
    for (final file in payload.files) {
      try {
        final cached = File(file.path);
        if (await cached.exists()) {
          await cached.delete();
        }
      } catch (_) {
        // Best-effort; the native side prunes stale copies.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _workspace.removeListener(_handleWorkspaceChanged);
    _receivers.clear();
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
