import 'package:conduit/core/diagnostics/app_error_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Broken extends StatelessWidget {
  const _Broken();

  @override
  Widget build(BuildContext context) => throw StateError('page broke');
}

void main() {
  test('keeps the newest errors up to its capacity, newest first in the '
      'report', () {
    final log = AppErrorLog(capacity: 2);
    log.recordError(StateError('one'), StackTrace.current);
    log.recordError(StateError('two'), null);
    log.recordError(StateError('three'), null);

    expect(log.entries.map((entry) => entry.summary), [
      'Bad state: two',
      'Bad state: three',
    ]);
    final report = log.report();
    expect(report, startsWith('Conductore error log (2 errors'));
    expect(report.indexOf('three'), lessThan(report.indexOf('two')));
  });

  testWidgets('a widget that fails to build shows the error card, which '
      'copies the log', (tester) async {
    final log = AppErrorLog();
    final previousOnError = FlutterError.onError;
    final previousBuilder = ErrorWidget.builder;
    final previousPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = previousOnError;
      PlatformDispatcher.instance.onError = previousPlatform;
    });
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    log.install(replaceErrorWidget: true);
    // The test framework's own handler would fail the test; the log's
    // handler chains to it, so swap in a quiet one underneath.
    final installed = FlutterError.onError!;
    FlutterError.onError = log.recordFlutterError;
    await tester.pumpWidget(const MaterialApp(home: _Broken()));
    FlutterError.onError = installed;

    expect(find.byKey(const ValueKey('app-error-card')), findsOneWidget);
    expect(find.textContaining('page broke'), findsWidgets);
    expect(log.entries.single.summary, 'Bad state: page broke');

    await tester.tap(find.byKey(const ValueKey('app-error-copy')));
    await tester.pump();
    expect(copied, contains('page broke'));
    expect(copied, contains('building _Broken'));
    // The test binding checks this before tear-down callbacks run.
    ErrorWidget.builder = previousBuilder;
  });

  test('install records framework errors and still reports them', () {
    final log = AppErrorLog();
    final previousOnError = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    final reported = <FlutterErrorDetails>[];
    FlutterError.onError = reported.add;
    addTearDown(() {
      FlutterError.onError = previousOnError;
      PlatformDispatcher.instance.onError = previousPlatform;
    });

    // Explicit: the default depends on the build mode.
    // ignore: avoid_redundant_argument_values
    log.install(replaceErrorWidget: false);
    FlutterError.reportError(
      FlutterErrorDetails(exception: StateError('layout broke')),
    );
    final handled = PlatformDispatcher.instance.onError!(
      StateError('async broke'),
      StackTrace.empty,
    );

    expect(reported, hasLength(1));
    expect(handled, isFalse);
    expect(log.entries.map((entry) => entry.summary), [
      'Bad state: layout broke',
      'Bad state: async broke',
    ]);
  });

  test('the barcode model download is an expected state, not an error', () {
    // GlitchTip #563: mobile_scanner's torch and zoom listeners leave the
    // per-frame "waiting for the barcode module" error uncaught.
    final log = AppErrorLog();
    final reported = <Object>[];
    log.onRecord = (error, _) => reported.add(error);
    final previousOnError = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = previousOnError;
      PlatformDispatcher.instance.onError = previousPlatform;
    });
    // Explicit: the default depends on the build mode.
    // ignore: avoid_redundant_argument_values
    log.install(replaceErrorWidget: false);

    final handled = PlatformDispatcher.instance.onError!(
      PlatformException(
        code: 'MOBILE_SCANNER_BARCODE_ERROR',
        message:
            'Waiting for the barcode module to be downloaded. Please wait.',
      ),
      StackTrace.empty,
    );
    PlatformDispatcher.instance.onError!(
      PlatformException(
        code: 'MOBILE_SCANNER_BARCODE_ERROR',
        message: 'Camera closed',
      ),
      StackTrace.empty,
    );

    expect(handled, isTrue);
    expect(log.entries.map((entry) => entry.summary), [
      'PlatformException(MOBILE_SCANNER_BARCODE_ERROR, Camera closed, null, '
          'null)',
    ]);
    expect(reported, hasLength(1));
  });
}
