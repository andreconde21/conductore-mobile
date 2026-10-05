import 'package:conduit/features/agent_attention/presentation/agent_monitoring_lifecycle.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a desktop keeps monitoring while another window has focus or it '
      'is minimized (CON-089)', () {
    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      expect(
        agentMonitoringActive(AppLifecycleState.inactive, platform),
        isTrue,
      );
      expect(agentMonitoringActive(AppLifecycleState.hidden, platform), isTrue);
      expect(
        agentMonitoringActive(AppLifecycleState.detached, platform),
        isFalse,
      );
    }
  });

  test('Android keeps it in the background; iOS pauses it', () {
    expect(
      agentMonitoringActive(AppLifecycleState.paused, TargetPlatform.android),
      isTrue,
    );
    expect(
      agentMonitoringActive(AppLifecycleState.paused, TargetPlatform.iOS),
      isFalse,
    );
    expect(
      agentMonitoringActive(AppLifecycleState.inactive, TargetPlatform.iOS),
      isTrue,
    );
  });
}
