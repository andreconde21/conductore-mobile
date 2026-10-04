import 'dart:convert';

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A fake token: no test ever sees a real one.
const fakeToken = 'fake-token-not-real';

/// A [MockClient] answering from recorded bodies keyed "METHOD /path"
/// (a value is a body, or (status, body); null answers 204), recording
/// every request. No request leaves the test.
class HttpRecorder {
  HttpRecorder(this.routes);

  final Map<String, Object?> routes;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    final key = '${request.method} ${request.url.path}';
    if (!routes.containsKey(key)) {
      return jsonResponse({'message': 'no route $key'}, 404);
    }
    final answer = routes[key];
    if (answer is (int, Object?)) return jsonResponse(answer.$2, answer.$1);
    if (answer is Object? Function(http.Request)) {
      return jsonResponse(answer(request), 200);
    }
    return answer == null ? http.Response('', 204) : jsonResponse(answer, 200);
  });

  http.Request last(String method) =>
      requests.lastWhere((r) => r.method == method);

  Object? lastJson(String method) => jsonDecode(last(method).body);
}

/// UTF-8 JSON without a charset, as some APIs answer.
http.Response jsonResponse(Object? body, int status) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

TaskSourceConfig sourceConfig(
  TaskSourceKind kind,
  Map<String, String> settings,
) => TaskSourceConfig(
  id: 's1',
  kind: kind,
  name: kind.label,
  settings: settings,
);

TaskItem itemRef(String id, {Map<String, String> extra = const {}}) =>
    TaskItem(sourceId: 's1', id: id, key: id, title: '', extra: extra);
