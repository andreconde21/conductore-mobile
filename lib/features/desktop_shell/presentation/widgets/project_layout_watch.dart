import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:flutter/widgets.dart';

/// Keeps [controller] re-reading the machines' layouts and sheprd's view
/// while [child] (a project view) is on screen.
class ProjectLayoutWatch extends StatefulWidget {
  const ProjectLayoutWatch({
    required this.controller,
    required this.child,
    super.key,
  });

  final ProjectLayoutController controller;
  final Widget child;

  @override
  State<ProjectLayoutWatch> createState() => _ProjectLayoutWatchState();
}

class _ProjectLayoutWatchState extends State<ProjectLayoutWatch> {
  late VoidCallback _unwatch = widget.controller.watch();

  @override
  void didUpdateWidget(ProjectLayoutWatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _unwatch();
    _unwatch = widget.controller.watch();
  }

  @override
  void dispose() {
    _unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
