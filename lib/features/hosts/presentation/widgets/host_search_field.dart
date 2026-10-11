import 'package:flutter/material.dart';

class HostSearchField extends StatelessWidget {
  const HostSearchField({
    required this.controller,
    required this.onChanged,
    required this.hasContent,
    required this.onClear,
    this.hintText = 'Search machines, hosts, tags…',
    this.height,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool hasContent;
  final VoidCallback onClear;
  final String hintText;

  /// A fixed height, to line up with a control beside it; null keeps the
  /// field's own.
  final double? height;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        contentPadding: _padding(context),
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        suffixIcon: hasContent
            ? IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  controller.clear();
                  onClear();
                },
              )
            : null,
      ),
    );
  }

  /// With [height], pads the text line up to it (a dense field is as tall
  /// as its content).
  EdgeInsetsGeometry? _padding(BuildContext context) {
    final height = this.height;
    if (height == null) return null;
    final theme = Theme.of(context);
    final line = TextPainter(
      text: TextSpan(text: hintText, style: theme.textTheme.bodyLarge),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final lineHeight = line.height;
    line.dispose();
    final vertical = ((height - lineHeight) / 2).clamp(0.0, height);
    final themed = theme.inputDecorationTheme.contentPadding?.resolve(
      Directionality.of(context),
    );
    return EdgeInsetsDirectional.fromSTEB(
      themed?.left ?? 12,
      vertical,
      themed?.right ?? 12,
      vertical,
    );
  }
}
