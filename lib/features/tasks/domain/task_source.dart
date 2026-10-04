import 'package:flutter/foundation.dart';

/// Task sources (CON-039): one small, public interface every tracker
/// adapter implements (list, read, change status, comment), each adapter
/// declaring what it can do. The open "markdown tasks folder" format
/// (docs/task-sources.md) is one adapter; GitHub Issues, GitLab Issues,
/// Jira Cloud, Linear and Azure Boards are others. Tokens live in this
/// device's secure storage only and are never synced.

/// Where a status sits in a task's life, whatever the tracker calls it.
enum TaskStatusCategory {
  todo('To do'),
  inProgress('In progress'),
  done('Done'),
  unknown('Other');

  const TaskStatusCategory(this.label);

  final String label;

  /// A best guess from a status name (the markdown folder has no
  /// categories of its own).
  static TaskStatusCategory guess(String name) {
    final n = name.toLowerCase().replaceAll(RegExp('[ _]'), '-');
    const done = {
      'done',
      'closed',
      'complete',
      'completed',
      'resolved',
      'merged',
      'pr-merged',
      'deployed',
      'cancelled',
      'canceled',
      'wontfix',
      'removed',
    };
    const todo = {'backlog', 'todo', 'to-do', 'open', 'new', 'proposed'};
    if (done.contains(n)) return TaskStatusCategory.done;
    if (todo.contains(n)) return TaskStatusCategory.todo;
    if (n.isEmpty) return TaskStatusCategory.unknown;
    return TaskStatusCategory.inProgress;
  }
}

/// One status a task can be moved to. [id] is what the tracker takes (a
/// name, a state id, a Jira transition id); [label] is what it shows.
@immutable
class TaskStatusOption {
  const TaskStatusOption({
    required this.id,
    required this.label,
    required this.category,
  });

  /// A status known by name only.
  TaskStatusOption.named(String name)
    : id = name,
      label = name,
      category = TaskStatusCategory.guess(name);

  final String id;
  final String label;
  final TaskStatusCategory category;

  @override
  bool operator ==(Object other) =>
      other is TaskStatusOption && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'TaskStatusOption($id, $label, $category)';
}

/// What an adapter supports; the UI hides the rest.
@immutable
class TaskSourceCapabilities {
  const TaskSourceCapabilities({
    this.statuses = true,
    this.comments = true,
    this.labels = true,
    this.assignees = true,
  });

  /// Tasks have a status and it can be changed.
  final bool statuses;

  /// Comments can be read and added.
  final bool comments;
  final bool labels;
  final bool assignees;
}

@immutable
class TaskComment {
  const TaskComment({required this.author, required this.body, this.at});

  final String author;
  final String body;
  final DateTime? at;
}

/// One task as every source reports it.
@immutable
class TaskItem {
  const TaskItem({
    required this.sourceId,
    required this.id,
    required this.key,
    required this.title,
    this.status,
    this.assignees = const [],
    this.labels = const [],
    this.url,
    this.updatedAt,
    this.body,
    this.comments,
    this.extra = const {},
  });

  /// The [TaskSourceConfig.id] it came from.
  final String sourceId;

  /// What the source's API addresses it by (an issue number, a Linear
  /// node id, a file name).
  final String id;

  /// What people call it (`#12`, `PROJ-7`, `CON-039`).
  final String key;
  final String title;
  final TaskStatusOption? status;
  final List<String> assignees;
  final List<String> labels;

  /// Where it opens in a browser.
  final String? url;
  final DateTime? updatedAt;

  /// Markdown or plain text; null until [TaskSource.read].
  final String? body;

  /// Null until [TaskSource.read] (or when the source has none).
  final List<TaskComment>? comments;

  /// Adapter-private values (a Jira issue's id, a work item's type).
  final Map<String, String> extra;

  /// `sourceId/id`: unique across sources.
  String get ref => '$sourceId/$id';

  TaskItem copyWith({
    TaskStatusOption? status,
    String? body,
    List<TaskComment>? comments,
  }) => TaskItem(
    sourceId: sourceId,
    id: id,
    key: key,
    title: title,
    status: status ?? this.status,
    assignees: assignees,
    labels: labels,
    url: url,
    updatedAt: updatedAt,
    body: body ?? this.body,
    comments: comments ?? this.comments,
    extra: extra,
  );
}

/// A failure an adapter reports; [message] is shown as is.
class TaskSourceFailure implements Exception {
  const TaskSourceFailure(this.code, this.message);

  /// `auth`, `not-found`, `network`, `bad-config`, `unsupported`, `failed`.
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// The public interface every tracker adapter implements.
abstract class TaskSource {
  TaskSourceConfig get config;

  TaskSourceCapabilities get capabilities;

  /// The open tasks first, at most a page's worth (newest first).
  Future<List<TaskItem>> list();

  /// [task] with its body and, when the source has them, its comments.
  Future<TaskItem> read(TaskItem task);

  /// What [task] can be moved to (Jira: its transitions).
  Future<List<TaskStatusOption>> statusOptions(TaskItem task);

  /// Moves [task] to [status]; the task as it is now.
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status);

  /// Adds [text] as a comment on [task].
  Future<void> comment(TaskItem task, String text);
}

/// A field of a source's settings form.
@immutable
class TaskSourceField {
  const TaskSourceField(
    this.key,
    this.label, {
    this.hint = '',
    this.help,
    this.required = true,
    this.kind = TaskSourceFieldKind.text,
    this.initial,
  });

  final String key;
  final String label;
  final String hint;
  final String? help;
  final bool required;
  final TaskSourceFieldKind kind;
  final String? initial;
}

enum TaskSourceFieldKind { text, url, email, machine }

/// The trackers Conductore talks to.
enum TaskSourceKind {
  markdownFolder(
    'markdown',
    'Markdown folder',
    'One .md file per task (YAML frontmatter) in a folder on a machine, '
        'read and written through its companion.',
    TaskSourceCapabilities(),
    null,
    [
      TaskSourceField(
        'host',
        'Machine',
        kind: TaskSourceFieldKind.machine,
        help: 'A machine with the Conductore companion.',
      ),
      TaskSourceField(
        'folder',
        'Folder',
        hint: '~/tasks/my-project',
        help: 'An absolute path (or ~/...). Only this folder is touched.',
      ),
    ],
  ),
  github(
    'github',
    'GitHub Issues',
    'Issues of one repository.',
    TaskSourceCapabilities(),
    'Personal access token (Issues: read and write)',
    [
      TaskSourceField('repo', 'Repository', hint: 'owner/name'),
      TaskSourceField(
        'apiBase',
        'API URL',
        hint: 'https://api.github.com',
        required: false,
        kind: TaskSourceFieldKind.url,
        help: 'Only for GitHub Enterprise Server (https://host/api/v3).',
      ),
    ],
  ),
  githubProjects(
    'github-projects',
    'GitHub Projects',
    'Items of a GitHub project (v2) board and their status field.',
    TaskSourceCapabilities(),
    'Personal access token (classic: project, repo; or fine-grained)',
    [
      TaskSourceField('owner', 'Owner', hint: 'my-org or my-user'),
      TaskSourceField('number', 'Project number', hint: '3'),
      TaskSourceField(
        'statusField',
        'Status field',
        hint: 'Status',
        required: false,
        help: 'A single-select field of the project.',
      ),
      TaskSourceField(
        'apiBase',
        'API URL',
        hint: 'https://api.github.com',
        required: false,
        kind: TaskSourceFieldKind.url,
        help: 'Only for GitHub Enterprise Server (https://host/api/v3).',
      ),
    ],
  ),
  gitlab(
    'gitlab',
    'GitLab Issues',
    'Issues of one project on gitlab.com or your own GitLab.',
    TaskSourceCapabilities(),
    'Personal access token (scope: api)',
    [
      TaskSourceField('project', 'Project', hint: 'group/project'),
      TaskSourceField(
        'baseUrl',
        'GitLab URL',
        hint: 'https://gitlab.com',
        required: false,
        kind: TaskSourceFieldKind.url,
      ),
    ],
  ),
  jira(
    'jira',
    'Jira Cloud',
    'Issues of a Jira Cloud project (or any JQL).',
    TaskSourceCapabilities(),
    'API token (id.atlassian.com › Security)',
    [
      TaskSourceField(
        'site',
        'Site',
        hint: 'https://your-team.atlassian.net',
        kind: TaskSourceFieldKind.url,
      ),
      TaskSourceField(
        'email',
        'Account email',
        kind: TaskSourceFieldKind.email,
      ),
      TaskSourceField('project', 'Project key', hint: 'PROJ', required: false),
      TaskSourceField(
        'jql',
        'JQL',
        hint: 'assignee = currentUser() ORDER BY updated DESC',
        required: false,
        help: 'Overrides the project key.',
      ),
    ],
  ),
  jiraServer(
    'jira-server',
    'Jira Server / Data Center',
    'Issues of a self-hosted Jira project (or any JQL).',
    TaskSourceCapabilities(),
    'Personal access token (Profile › Personal Access Tokens)',
    [
      TaskSourceField(
        'site',
        'Server URL',
        hint: 'https://jira.example.com',
        kind: TaskSourceFieldKind.url,
      ),
      TaskSourceField('project', 'Project key', hint: 'PROJ', required: false),
      TaskSourceField(
        'jql',
        'JQL',
        hint: 'assignee = currentUser() ORDER BY updated DESC',
        required: false,
        help: 'Overrides the project key.',
      ),
    ],
  ),
  linear(
    'linear',
    'Linear',
    'Issues of a Linear team (or every team).',
    TaskSourceCapabilities(),
    'Personal API key (Settings › Security & access)',
    [
      TaskSourceField(
        'team',
        'Team key',
        hint: 'ENG',
        required: false,
        help: 'Empty: issues of every team you can see.',
      ),
    ],
  ),
  trello(
    'trello',
    'Trello',
    "Cards of a Trello board; a card's list is its status.",
    TaskSourceCapabilities(),
    'Token (authorize your API key at trello.com/1/authorize)',
    [
      TaskSourceField(
        'board',
        'Board',
        hint: 'the code in trello.com/b/<code>/…',
      ),
      TaskSourceField(
        'apiKey',
        'API key',
        help:
            'From trello.com/power-ups/admin. The key identifies the app; '
            'the token below is the secret.',
      ),
    ],
  ),
  clickup(
    'clickup',
    'ClickUp',
    'Tasks of a ClickUp list, with its statuses.',
    TaskSourceCapabilities(),
    'Personal API token (Settings › Apps, starts with pk_)',
    [TaskSourceField('list', 'List id', hint: 'the number in …/li/<id>')],
  ),
  asana(
    'asana',
    'Asana',
    'Tasks of an Asana project; sections are statuses, plus Completed.',
    TaskSourceCapabilities(),
    'Personal access token (My settings › Apps › Developer apps)',
    [
      TaskSourceField(
        'project',
        'Project id',
        hint: 'the number in app.asana.com/0/<id>/…',
      ),
    ],
  ),
  notion(
    'notion',
    'Notion database',
    'Pages of a Notion database, with a status or select property.',
    TaskSourceCapabilities(),
    'Internal integration secret (share the database with the integration)',
    [
      TaskSourceField('database', 'Database', hint: 'its id, or its URL'),
      TaskSourceField(
        'statusProperty',
        'Status property',
        hint: 'Status',
        required: false,
        help: 'A status or select property of the database.',
      ),
    ],
  ),
  azureBoards(
    'azure-boards',
    'Azure Boards',
    'Work items of an Azure DevOps project.',
    TaskSourceCapabilities(),
    'Personal access token (Work Items: read and write)',
    [
      TaskSourceField('organization', 'Organization', hint: 'my-org'),
      TaskSourceField('project', 'Project', hint: 'My Project'),
      TaskSourceField(
        'baseUrl',
        'Server URL',
        hint: 'https://dev.azure.com',
        required: false,
        kind: TaskSourceFieldKind.url,
        help: 'Only for Azure DevOps Server.',
      ),
    ],
  );

  const TaskSourceKind(
    this.wire,
    this.label,
    this.description,
    this.capabilities,
    this.tokenLabel,
    this.fields,
  );

  /// As stored.
  final String wire;
  final String label;
  final String description;
  final TaskSourceCapabilities capabilities;

  /// Null when the source needs no token (the markdown folder).
  final String? tokenLabel;
  final List<TaskSourceField> fields;

  bool get needsToken => tokenLabel != null;

  static TaskSourceKind? parse(Object? wire) {
    for (final kind in values) {
      if (kind.wire == wire) return kind;
    }
    return null;
  }
}

/// A configured source: its kind, a name and the non-secret settings. The
/// token is stored apart, per device.
@immutable
class TaskSourceConfig {
  const TaskSourceConfig({
    required this.id,
    required this.kind,
    required this.name,
    this.settings = const {},
  });

  final String id;
  final TaskSourceKind kind;
  final String name;
  final Map<String, String> settings;

  /// A trimmed setting, or null when empty.
  String? operator [](String key) {
    final v = settings[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  /// The first missing required field's label, or null.
  String? missingField() {
    for (final field in kind.fields) {
      if (field.required && this[field.key] == null) return field.label;
    }
    if ((kind == TaskSourceKind.jira || kind == TaskSourceKind.jiraServer) &&
        this['project'] == null &&
        this['jql'] == null) {
      return 'Project key or JQL';
    }
    return null;
  }

  TaskSourceConfig copyWith({String? name, Map<String, String>? settings}) =>
      TaskSourceConfig(
        id: id,
        kind: kind,
        name: name ?? this.name,
        settings: settings ?? this.settings,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.wire,
    'name': name,
    'settings': settings,
  };

  static TaskSourceConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = TaskSourceKind.parse(json['kind']);
    final id = json['id'];
    if (kind == null || id is! String || id.isEmpty) return null;
    final settings = json['settings'];
    return TaskSourceConfig(
      id: id,
      kind: kind,
      name: json['name'] is String ? json['name'] as String : kind.label,
      settings: {
        if (settings is Map)
          for (final e in settings.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
      },
    );
  }
}
