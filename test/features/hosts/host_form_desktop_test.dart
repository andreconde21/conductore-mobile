import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/ssh_key.dart';
import 'package:conduit/features/hosts/presentation/host_form_page.dart';
import 'package:conduit/features/hosts/presentation/public_key_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

final _desktops = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
  TargetPlatform.macOS,
});

const _details = SshKeyDetails(
  algorithm: SshKeyAlgorithm.ed25519,
  fingerprintSha256: 'SHA256:abc',
  publicKeyOpenSsh: 'ssh-ed25519 AAAA test',
  comment: 'test',
);

/// A launcher that opens the form and records what it returned.
Widget _launcher(void Function(Future<SavedHost?>) onResult, SavedHost? host) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => onResult(openHostForm(context, host: host)),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('desktop opens the form as a dialog with Cancel / Save and '
      'Ctrl+S saves', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<SavedHost?>? result;
    await tester.pumpWidget(_launcher((r) => result = r, buildHost('h')));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-page-frame')), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);

    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final modifier = mac
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.tap(find.byType(TextFormField).first);
    await tester.pump();
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();

    expect(find.byType(HostFormPage), findsNothing);
    expect((await result)?.id, 'h');
  }, variant: _desktops);

  testWidgets(
    'desktop Cancel closes the form without saving',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<SavedHost?>? result;
      await tester.pumpWidget(_launcher((r) => result = r, null));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(HostFormPage), findsNothing);
      expect(await result, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('phones push the form full screen with the full-width button '
      'and no Cancel', (tester) async {
    Future<SavedHost?>? result;
    await tester.pumpWidget(_launcher((r) => result = r, null));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopPageRoute<SavedHost>), findsNothing);
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
    final route = ModalRoute.of(tester.element(find.byType(HostFormPage)));
    expect(route, isA<MaterialPageRoute<SavedHost>>());
    expect(result, isNotNull);
  });

  testWidgets('desktop public key dialog sizes to its content and has '
      'Done', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showPublicKeySheet(context: context, details: _details),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Public key'), findsNothing);
  }, variant: _desktops);

  testWidgets('phones keep the draggable public key sheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showPublicKeySheet(context: context, details: _details),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });
}
