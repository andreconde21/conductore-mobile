import 'dart:async';

import 'package:conduit/core/diagnostics/app_error_log.dart';
import 'package:conduit/features/sync/domain/sync_setup_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Whether this build can scan setup codes with the camera: phones only.
/// Desktops paste the code instead.
bool get setupCodeScanningAvailable =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// What a scanner shows while Google Play services downloads the barcode
/// model on first use.
const scannerGettingReadyText = 'Getting the scanner ready…';

/// Tracks the barcode model download on a fresh install: every frame fails
/// with "waiting for the barcode module" until it is there, and the camera
/// keeps scanning, so the first frame that works ends the wait by itself.
/// [gettingReady] holds until no such error has come for [settle].
class ScannerReadiness extends ChangeNotifier {
  ScannerReadiness({this.settle = const Duration(seconds: 2)});

  final Duration settle;
  Timer? _timer;

  bool get gettingReady => _timer?.isActive ?? false;

  /// For MobileScanner.onDetectError. Other scan errors stay ignored, as
  /// they were.
  void onDetectError(Object error, StackTrace stack) {
    if (error is! MobileScannerBarcodeException ||
        !isBarcodeModuleDownloading(error.message)) {
      return;
    }
    final wasReady = !gettingReady;
    _timer?.cancel();
    _timer = Timer(settle, notifyListeners);
    if (wasReady) notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Opens the camera and returns the first Conductore setup code it sees.
Future<String?> scanSetupCode(BuildContext context) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => const _SetupCodeScannerPage()),
  );
}

class _SetupCodeScannerPage extends StatefulWidget {
  const _SetupCodeScannerPage();

  @override
  State<_SetupCodeScannerPage> createState() => _SetupCodeScannerPageState();
}

class _SetupCodeScannerPageState extends State<_SetupCodeScannerPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  final _readiness = ScannerReadiness();
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    _readiness.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      if (SyncSetupOffer.decode(value) != null) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
      setState(() => _hint = 'That QR code is not a Conductore setup code.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan setup code')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            onDetectError: _readiness.onDetectError,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'The camera is not available (${error.errorCode.name}). '
                  'Paste the setup code instead.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListenableBuilder(
                  listenable: _readiness,
                  builder: (context, _) => Text(
                    _readiness.gettingReady
                        ? scannerGettingReadyText
                        : _hint ??
                              'Point the camera at the QR code shown under '
                                  'Settings › Sync › Add a device on your '
                                  'other device.',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
