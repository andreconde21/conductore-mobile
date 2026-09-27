import 'dart:async';

import 'package:conduit/core/diagnostics/app_error_log.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_config.dart';
import 'package:conduit/core/telemetry/telemetry_preferences.dart';
import 'package:conduit/core/telemetry/telemetry_scrubber.dart';
import 'package:conduit/core/telemetry/telemetry_terms.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Replaces the inert [Telemetry.instance] with the app's, routes the
/// error log into it and starts it. Crash reports are scrubbed of every
/// saved machine's names, addresses, users and secrets, and of the terms
/// features add at run time ([addTelemetryTerms]), read at report time.
void startTelemetry({
  required FlutterSecureStorage storage,
  required HostsController hosts,
  required ThemeController theme,
}) {
  final telemetry = Telemetry(
    config: TelemetryConfig.fromEnvironment(),
    store: SecureTelemetryPreferencesStore(storage),
    scrubber: TelemetryScrubber(
      sensitiveTerms: () => [
        // Every saved machine, one hidden as "This computer" included.
        ...savedHostTerms([?hosts.thisComputer, ...hosts.hosts]),
        ...deviceTerms(),
        // Claude account labels (cswap), among others.
        ...runtimeTerms(),
        for (final snippet in theme.terminalSnippets) ...[
          snippet.label,
          snippet.text,
        ],
      ],
    ),
  );
  Telemetry.instance = telemetry;
  AppErrorLog.instance.onRecord = telemetry.recordError;
  unawaited(telemetry.start());
}
