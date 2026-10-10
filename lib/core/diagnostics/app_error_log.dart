import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One error the app caught: a framework error (build, layout, paint) or an
/// uncaught asynchronous one.
class AppErrorEntry {
  const AppErrorEntry({
    required this.time,
    required this.summary,
    required this.details,
  });

  final DateTime time;

  /// One line: the exception's message.
  final String summary;

  /// The exception, where it happened, and the top of its stack.
  final String details;

  @override
  String toString() => '[${time.toIso8601String()}] $details';
}

/// The last [capacity] errors the app ran into, kept in memory so a release
/// build can show and share them (a failed build shows only a blank page
/// there otherwise).
class AppErrorLog extends ChangeNotifier {
  AppErrorLog({this.capacity = 20});

  static final instance = AppErrorLog();

  final int capacity;
  final _entries = Queue<AppErrorEntry>();

  /// Also hands every recorded error to this (crash reporting); what it
  /// throws is ignored, so the log keeps working.
  void Function(Object error, StackTrace? stack)? onRecord;

  /// Oldest first.
  List<AppErrorEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  static const _stackLines = 25;

  /// Records a framework error.
  AppErrorEntry recordFlutterError(FlutterErrorDetails details) {
    final buffer = StringBuffer(details.exceptionAsString());
    final context = details.context?.toDescription();
    if (context != null && context.isNotEmpty) {
      buffer.write('\nThrown $context');
    }
    if (details.library != null) {
      buffer.write(' (${details.library})');
    }
    _appendStack(buffer, details.stack);
    _forward(details.exception, details.stack);
    return _add(details.exceptionAsString(), buffer.toString());
  }

  /// Records an error nothing else caught.
  AppErrorEntry recordError(Object error, StackTrace? stack) {
    final buffer = StringBuffer('Uncaught: $error');
    _appendStack(buffer, stack);
    _forward(error, stack);
    return _add('$error', buffer.toString());
  }

  void _forward(Object error, StackTrace? stack) {
    try {
      onRecord?.call(error, stack);
    } on Object {
      // Reporting is best effort.
    }
  }

  static void _appendStack(StringBuffer buffer, StackTrace? stack) {
    if (stack == null) return;
    final lines = stack
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(_stackLines);
    buffer
      ..write('\n')
      ..writeAll(lines, '\n');
  }

  AppErrorEntry _add(String summary, String details) {
    final entry = AppErrorEntry(
      time: DateTime.now(),
      summary: summary.split('\n').first,
      details: details,
    );
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    notifyListeners();
    return entry;
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Everything recorded, newest first, ready to paste into a bug report.
  String report() {
    final buffer = StringBuffer(
      'Conductore error log (${_entries.length} '
      '${_entries.length == 1 ? 'error' : 'errors'}, newest first)\n',
    );
    for (final entry in _entries.toList().reversed) {
      buffer
        ..write('\n')
        ..write(entry)
        ..write('\n');
    }
    return buffer.toString();
  }

  Future<void> copyReport() => Clipboard.setData(ClipboardData(text: report()));

  /// Routes framework and uncaught errors into this log (still reporting
  /// them as before) and, outside debug builds, replaces the blank page a
  /// failed build leaves with [AppErrorCard].
  void install({bool replaceErrorWidget = !kDebugMode}) {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      recordFlutterError(details);
      (previousFlutter ?? FlutterError.presentError)(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      if (isExpectedUncaughtError(error)) return true;
      recordError(error, stack);
      return previousPlatform?.call(error, stack) ?? false;
    };
    if (replaceErrorWidget) {
      ErrorWidget.builder = (details) =>
          AppErrorCard(details: details, log: this);
    }
  }
}

/// Whether [message] is ML Kit saying Google Play services is still
/// downloading the barcode model. The APK ships without it
/// (mobile_scanner useUnbundled), so the first scans on a fresh install
/// fail with this until the download is done; then scanning works by itself.
bool isBarcodeModuleDownloading(String? message) =>
    message?.toLowerCase().contains('module to be downloaded') ?? false;

/// Uncaught errors that are an expected state, not a fault: neither logged
/// nor reported. mobile_scanner's torch and zoom listeners share the barcode
/// event stream without an error handler, so every frame that fails while
/// the barcode model downloads also surfaces here as uncaught.
bool isExpectedUncaughtError(Object error) =>
    error is PlatformException &&
    error.code == 'MOBILE_SCANNER_BARCODE_ERROR' &&
    isBarcodeModuleDownloading(error.message);

/// What a widget that failed to build shows instead of a blank page: the
/// error, where it happened, and a button that copies the error log.
///
/// Built from plain widgets with its own colours and text direction: it can
/// appear anywhere, including above the MaterialApp.
class AppErrorCard extends StatelessWidget {
  const AppErrorCard({required this.details, required this.log, super.key});

  final FlutterErrorDetails details;
  final AppErrorLog log;

  static String? _stackHead(StackTrace? stack) {
    if (stack == null) return null;
    final lines = stack
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(6)
        .toList();
    return lines.isEmpty ? null : lines.join('\n');
  }

  static const _background = Color(0xFF2B1D1F);
  static const _foreground = Color(0xFFF4E4E6);
  static const _accent = Color(0xFFFF8A80);

  @override
  Widget build(BuildContext context) {
    final where = details.context?.toDescription();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        key: const ValueKey('app-error-card'),
        color: _background,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Something went wrong here',
                style: TextStyle(
                  color: _accent,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This part of the screen failed to draw. Copy the error and '
                'send it to the developers; going back and reopening, or '
                'restarting the app, usually recovers.',
                style: TextStyle(color: _foreground, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Text(
                details.exceptionAsString(),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _foreground,
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
              if (_stackHead(details.stack) case final stack?) ...[
                const SizedBox(height: 6),
                Text(
                  stack,
                  style: TextStyle(
                    color: _foreground.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              if (where != null && where.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Thrown $where',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _foreground.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  key: const ValueKey('app-error-copy'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (log.isEmpty) log.recordFlutterError(details);
                    log.copyReport();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Copy error',
                      style: TextStyle(
                        color: _background,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
