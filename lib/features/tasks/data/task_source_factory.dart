import 'package:conduit/features/tasks/data/azure_boards_task_source.dart';
import 'package:conduit/features/tasks/data/github_projects_task_source.dart';
import 'package:conduit/features/tasks/data/github_task_source.dart';
import 'package:conduit/features/tasks/data/gitlab_task_source.dart';
import 'package:conduit/features/tasks/data/jira_task_source.dart';
import 'package:conduit/features/tasks/data/linear_task_source.dart';
import 'package:conduit/features/tasks/data/markdown_folder_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// The adapter for [config]. [token] is the source's token from this
/// device's secure storage; [companion] runs the markdown folder's
/// companion command.
TaskSource createTaskSource(
  TaskSourceConfig config, {
  required String? token,
  required CompanionTasksCall companion,
  http.Client? client,
}) {
  if (config.kind.needsToken && (token == null || token.isEmpty)) {
    throw TaskSourceFailure(
      'auth',
      '${config.name}: add a token in Settings › Tasks › Sources.',
    );
  }
  final t = token ?? '';
  return switch (config.kind) {
    TaskSourceKind.markdownFolder => MarkdownFolderTaskSource(
      config,
      call: companion,
    ),
    TaskSourceKind.github => GitHubTaskSource(config, token: t, client: client),
    TaskSourceKind.githubProjects => GitHubProjectsTaskSource(
      config,
      token: t,
      client: client,
    ),
    TaskSourceKind.gitlab => GitLabTaskSource(config, token: t, client: client),
    TaskSourceKind.jira || TaskSourceKind.jiraServer => JiraTaskSource(
      config,
      token: t,
      client: client,
    ),
    TaskSourceKind.linear => LinearTaskSource(config, token: t, client: client),
    TaskSourceKind.azureBoards => AzureBoardsTaskSource(
      config,
      token: t,
      client: client,
    ),
  };
}
