/// The home's workspace search (CON-105): what is typed, matched as a
/// case-insensitive substring of a row's names (pane title, workspace,
/// tab, project, machine). Empty matches everything.
class HomeSearch {
  HomeSearch(String query) : _needle = query.trim().toLowerCase();

  static final none = HomeSearch('');

  final String _needle;

  bool get isEmpty => _needle.isEmpty;

  /// Whether any of [fields] contains the query.
  bool matches(Iterable<String?> fields) =>
      isEmpty ||
      fields.any(
        (field) => field != null && field.toLowerCase().contains(_needle),
      );
}
