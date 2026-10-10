import 'package:flutter/material.dart';

/// The Agents button's icon, the same on home, in the terminal and on the
/// desktop: the heart monitor with the number of agents waiting on the user
/// (the agent monitor's attention count).
class AgentsIcon extends StatelessWidget {
  const AgentsIcon({required this.count, this.size, super.key});

  final int count;
  final double? size;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      child: Icon(Icons.monitor_heart_outlined, size: size),
    );
  }
}
