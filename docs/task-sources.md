# Task sources

Conductore lists, opens, moves and comments on tasks from several trackers
through one small interface (CON-039). The app depends on no proprietary
tracker: a private tracker plugs in either by writing the open markdown
folder format below or by implementing the interface in its own adapter.

## The interface

`lib/features/tasks/domain/task_source.dart`:

```dart
abstract class TaskSource {
  TaskSourceConfig get config;
  TaskSourceCapabilities get capabilities; // statuses, comments, labels, assignees
  Future<List<TaskItem>> list();                     // newest first, one page
  Future<TaskItem> read(TaskItem task);              // + body and comments
  Future<List<TaskStatusOption>> statusOptions(TaskItem task);
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status);
  Future<void> comment(TaskItem task, String text);
}
```

- A `TaskItem` has `id` (what the API addresses), `key` (what people call it:
  `#12`, `PROJ-7`, `CON-039`), `title`, `status`, `assignees`, `labels`,
  `url`, `updatedAt`, and after `read` its `body` and `comments`.
- A `TaskStatusOption` has the tracker's `id`, a `label`, and a `category`
  (`todo`, `inProgress`, `done`, `unknown`) so the app can group tasks and
  find a "done" status whatever the tracker calls it.
- Each adapter declares `TaskSourceCapabilities`; the UI hides what an
  adapter cannot do.
- Failures are `TaskSourceFailure(code, message)`; messages never carry the
  token.

## Adapters

| Kind | API | Auth | Statuses | Paging |
|---|---|---|---|---|
| Markdown folder | the companion's `tasks` command | SSH to the machine | the files' `status:` values | up to 2000 files |
| GitHub Issues | REST v3 (`api.github.com` or GHES `/api/v3`) | PAT, Bearer | open, closed | `page` |
| GitHub Projects (v2) | GraphQL | PAT, Bearer | the project's single-select field ("Status") | cursor |
| GitLab Issues | REST v4 (gitlab.com or self-managed) | PAT, `PRIVATE-TOKEN` | opened, closed | `page` |
| Jira Cloud | REST v3, `POST /search/jql` | email + API token, Basic | the issue's transitions | `nextPageToken` |
| Jira Server / Data Center | REST v2, `GET /search` | PAT, Bearer | the issue's transitions | `startAt` |
| Linear | GraphQL | personal API key | the team's workflow states | cursor |
| Trello | REST v1 | API key + token in the OAuth header | the board's lists | one call (up to 1000 cards) |
| ClickUp | API v2 | personal token | the list's statuses | `page` |
| Asana | REST 1.0 | PAT, Bearer | the project's sections, plus Completed | `offset` |
| Notion database | API 2022-06-28 | integration secret, Bearer | a status or select property ("Status") | cursor |
| Azure Boards | REST 7.1, WIQL | PAT, Basic | the work item type's states | ids read 200 at a time |

Every source loads at most 500 tasks (`maxTasksPerSource`), newest first.
The task list combines every source, or only the sources you choose. It
sorts by last update, status, source or key, and always breaks ties the
same way: newest update first, then source name, then key, with numbers in
keys compared as numbers. Each task shows a badge naming its source.

Only `https://` addresses are used (plain `http://` for localhost only).
Tokens live in this device's secure storage, one key per source
(`conductore.task_source_token.<id>`), and are not part of device sync;
the source list (`conductore.task_sources.v1`) holds no secret.

## The markdown tasks folder format

A folder holds one file per task, `<id>.md`, where `<id>` is a file name of
letters, digits, `.`, `_` and `-`. Each file starts with YAML frontmatter
between `---` lines, then a markdown body:

```markdown
---
id: CON-039
title: "Task sources: an open, documented interface"
status: in-progress
priority: medium
type: feature
assignee: andre
labels: [mobile, tasks]
created_at: "2026-09-27T15:23:59Z"
updated_at: "2026-09-27T15:29:05Z"
---

## Description

Free markdown.

## Comments

- André (2026-10-04T10:00:00Z): First comment
  continued on an indented line.
```

- Frontmatter is flat: `key: value` scalars (bare, `"double"` or `'single'`
  quoted), flow lists `[a, b]`, and block lists (`key:` then `  - item`).
  Unknown keys are kept and ignored.
- Known keys: `id` (shown as the key; the file name when absent), `title`
  (else the first `# heading`, else the id), `status`, `assignee` or
  `assignees`, `labels` or `tags`, `priority`, `type`, `created_at`,
  `updated_at` (ISO 8601).
- Statuses are free words. Readers treat `done`, `closed`, `completed`,
  `resolved`, `merged`, `deployed`, `cancelled` as done and `backlog`,
  `todo`, `open`, `new` as to do; anything else is in progress.
- A status change rewrites only the `status:` line (adding it when
  missing) and an existing `updated_at:` line. A comment is appended under
  a `## Comments` heading at the end of the body (created when missing) as
  `- <author> (<ISO time>): <text>`, continuation lines indented by two
  spaces. Everything else in the file stays byte for byte, line endings
  included.
- Files without frontmatter (a README) and dot files are skipped.

### Companion command

`conductore-hostd tasks <list|read|status|comment> -` takes one JSON
object on stdin (`{folder, id?, status?, text?, author?}`) and prints JSON
(capability `tasks-folder`). It only touches the given folder: the folder
must be an existing absolute directory (or `~/…`) other than `/`; ids are
plain file names without separators or `..`; a task file must be a regular
file directly inside the folder, never a symlink; writes go through a temp
file in the folder and a rename.
