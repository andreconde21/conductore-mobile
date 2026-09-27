/// Per-host memory of working directories the user has been in, most
/// recent first, fed by the shell (OSC 7), tmux and the companion's agents.
library;

import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';

/// How many directories are kept per host.
const maxRecentDirectories = 20;

/// Remembers the recent directories per saved host.
abstract class RecentDirectoriesStore {
  Future<List<String>> read(String hostId);

  Future<void> write(String hostId, List<String> directories);
}

class InMemoryRecentDirectoriesStore implements RecentDirectoriesStore {
  final Map<String, List<String>> directories = {};

  @override
  Future<List<String>> read(String hostId) async =>
      List.of(directories[hostId] ?? const <String>[]);

  @override
  Future<void> write(String hostId, List<String> value) async =>
      directories[hostId] = List.of(value);
}

/// Cleans a reported directory: absolute paths only (every source reports
/// them; a relative one would be ambiguous), trailing slashes dropped,
/// control characters and absurd lengths rejected. Null when unusable.
String? normalizeRecentDirectory(String raw) {
  var value = raw.trim();
  if (!value.startsWith('/') ||
      value.length > 4096 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// Adds [directory] to [current] (most recent first, capped at [max]).
///
/// With [promote] the directory moves to the top even when already known;
/// without it (periodic sources such as agent polls) a known directory
/// keeps its place so polling does not reshuffle the list.
List<String> pushRecentDirectory(
  List<String> current,
  String directory, {
  bool promote = true,
  int max = maxRecentDirectories,
}) {
  final normalized = normalizeRecentDirectory(directory);
  if (normalized == null) {
    return current;
  }
  if (!promote && current.contains(normalized)) {
    return current;
  }
  return [
    normalized,
    for (final existing in current)
      if (existing != normalized) existing,
  ].take(max).toList(growable: false);
}

/// Extracts the directory from an OSC 7 report (`ESC ] 7 ; file://host/path
/// BEL`), as the terminal hands it over: [args] is everything after the
/// `7`, split on `;`. The path is percent-decoded. Null when malformed.
String? parseOsc7Directory(List<String> args) {
  if (args.isEmpty) {
    return null;
  }
  // A `;` inside the path was split off by the parser; put it back.
  final raw = args.join(';').trim();
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      (uri.scheme != 'file' && uri.scheme != 'kitty-shell-cwd')) {
    return null;
  }
  final String path;
  try {
    path = Uri.decodeComponent(uri.path);
  } on ArgumentError {
    return null;
  }
  return normalizeRecentDirectory(path);
}

/// Quotes [value] for the login shell, whichever it is, and tmux's
/// command parser (see [shellQuoteArgument]) unless it is plainly safe.
String quoteDirectory(String value) =>
    RegExp(r'^[A-Za-z0-9_./:=+@%,-]+$').hasMatch(value)
    ? value
    : shellQuoteArgument(value);

/// Typed into the current shell to change to [directory].
String cdCommand(String directory) => 'cd ${quoteDirectory(directory)}';

/// Typed into tmux's command prompt (prefix, `:`) to open a new window
/// in [directory].
String tmuxNewWindowCommand(String directory) =>
    'new-window -c ${quoteDirectory(directory)}';

/// Arguments for `herdr tab create` opening a focused tab in [directory],
/// labelled with its last path segment.
String herdrNewTabArguments(String directory) {
  final segments = directory.split('/').where((s) => s.isNotEmpty);
  final label = segments.isEmpty ? '/' : segments.last;
  return 'tab create --cwd ${quoteDirectory(directory)} '
      '--label ${quoteDirectory(label)} --focus';
}

/// The last path segment, for compact display.
String directoryBasename(String directory) {
  final segments = directory.split('/').where((s) => s.isNotEmpty);
  return segments.isEmpty ? '/' : segments.last;
}
