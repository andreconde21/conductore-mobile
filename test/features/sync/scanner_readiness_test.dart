import 'package:conduit/features/sync/presentation/widgets/setup_code_scanner.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  // ML Kit's text while Google Play services downloads the barcode model
  // (GlitchTip #563).
  const downloading = MobileScannerBarcodeException(
    'Waiting for the barcode module to be downloaded. Please wait.',
  );

  test('says the scanner is getting ready until the model errors stop', () {
    fakeAsync((async) {
      final readiness = ScannerReadiness();
      var changes = 0;
      readiness.addListener(() => changes++);

      expect(readiness.gettingReady, isFalse);
      readiness.onDetectError(downloading, StackTrace.empty);
      expect(readiness.gettingReady, isTrue);
      expect(changes, 1);

      // Every frame fails while the download runs: still waiting, and no
      // rebuild per frame.
      for (var i = 0; i < 10; i++) {
        async.elapse(const Duration(milliseconds: 500));
        readiness.onDetectError(downloading, StackTrace.empty);
      }
      expect(readiness.gettingReady, isTrue);
      expect(changes, 1);

      // The model is there: frames stop failing and the wait ends.
      async.elapse(const Duration(seconds: 2));
      expect(readiness.gettingReady, isFalse);
      expect(changes, 2);
      readiness.dispose();
    });
  });

  test('other scan errors do not show the wait', () {
    final readiness = ScannerReadiness();
    readiness
      ..onDetectError(
        const MobileScannerBarcodeException('Could not decode'),
        StackTrace.empty,
      )
      ..onDetectError(StateError('camera'), StackTrace.empty);

    expect(readiness.gettingReady, isFalse);
    readiness.dispose();
  });
}
