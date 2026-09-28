// Desktop shell with four split terminals: one prints a build log at frame
// pace and animates its title (like Claude Code's spinner), the other
// three print a line a second. Reports ten seconds of it: widget rebuilds
// (whole-page ones show up as HostsPage/DesktopHome builds), paints and
// the frame time.
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/desktop_shell/shell_harness.dart';
import '../support/test_doubles.dart';
import 'perf_probe.dart';

void main() {
  for (final panes in [4, 6]) {
    testWidgets(
      'desktop shell: $panes splits with live output',
      (tester) async {
        final h = await pumpShell(tester, size: const Size(1920, 1080));
        final sessions = <TerminalSessionController>[
          await h.open(tester, workstation, const ConnectTarget.tmux('main')),
          await h.open(tester, buildBox, const ConnectTarget.tmux('ci')),
          for (final id in ['c', 'd', 'e', 'f'].take(panes - 2))
            await h.open(
              tester,
              buildHost(id).copyWith(name: id),
              ConnectTarget.tmux(id),
            ),
        ];
        h.shell.showHome = false;
        String view(TerminalSessionController s) => 'session:${s.host.id}';
        var layout = ShellLayout.single(view(sessions[0]))
            .split('p1', ShellEdge.right, view(sessions[1]))
            .split('p1', ShellEdge.bottom, view(sessions[2]))
            .split('p2', ShellEdge.bottom, view(sessions[3]));
        if (panes == 6) {
          // The 3×2 grid: a third column.
          layout = layout
              .split('p2', ShellEdge.right, view(sessions[4]))
              .split('p4', ShellEdge.right, view(sessions[5]));
        }
        h.shell.layout.value = layout;
        await settleShell(tester);
        expect(h.shell.layout.value.panes, hasLength(panes));

        final probe = FrameProbe()..install();
        var frameUs = 0;
        const frames = 600;
        try {
          for (var f = 0; f < frames; f++) {
            final busy = h.terminals.session(sessions[0].host.id)!;
            busy.print(
              '\x1b]0;${'⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'[f % 10]} Working\x07'
              'compile step $f of the build … ok\r\n',
            );
            if (f % 60 == 0) {
              for (final s in sessions.skip(1)) {
                h.terminals.session(s.host.id)!.print('tick $f\r\n');
              }
            }
            final watch = Stopwatch()..start();
            await tester.pump(const Duration(milliseconds: 16));
            frameUs += watch.elapsedMicroseconds;
          }
        } finally {
          probe.uninstall();
        }
        perfReport('shell.${panes}_splits_10s', {
          'frames': frames,
          'builds': probe.builds,
          'paints': probe.paints,
          'page_builds':
              (probe.buildsByType['HostsPage'] ?? 0) +
              (probe.buildsByType['DesktopHome'] ?? 0),
          'avg_frame_ms': (frameUs / frames / 1000).toStringAsFixed(2),
          'top': probe.top(8).replaceAll(' ', ','),
          'top_paints': probe.topPaints(40).replaceAll(' ', ','),
        });
        // Output stays inside the busy terminal: before the terminal was a
        // relayout and repaint boundary, every line repainted ~640 render
        // objects of the shell around it.
        expect(probe.paints, lessThan(frames * 20));
        await tearDownShell(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}
