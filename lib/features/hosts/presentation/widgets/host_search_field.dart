import 'package:flutter/material.dart';

class HostSearchField extends StatelessWidget {
  const HostSearchField({
    required this.controller,
    required this.onChanged,
    required this.hasContent,
    required this.onClear,
    this.hintText = 'Search machines, hosts, tags…',
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool hasContent;
  final VoidCallback onClear;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
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
}
