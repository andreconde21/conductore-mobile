import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// JSON over HTTPS for the tracker adapters: one place that sets the
/// headers, bounds the time and turns failures into [TaskSourceFailure]s
/// that never carry the token.
class TaskHttp {
  TaskHttp(this.client, {required this.service, required this.headers});

  final http.Client client;

  /// "GitHub", "Jira", ... for messages.
  final String service;

  /// Auth and accept headers sent with every request.
  final Map<String, String> headers;

  static const timeout = Duration(seconds: 20);

  Future<Object?> get(Uri uri) => send('GET', uri);

  Future<Object?> send(
    String method,
    Uri uri, {
    Object? body,
    String contentType = 'application/json',
  }) async {
    if (uri.scheme != 'https' && !_isLocal(uri)) {
      throw TaskSourceFailure(
        'bad-config',
        '$service: only https:// addresses are used.',
      );
    }
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) {
      request.headers['content-type'] = contentType;
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw TaskSourceFailure('network', '$service did not answer in time.');
    } on SocketException catch (e) {
      throw TaskSourceFailure('network', '$service: ${e.message}');
    } on http.ClientException catch (e) {
      throw TaskSourceFailure('network', '$service: ${e.message}');
    }
    final status = response.statusCode;
    Object? json;
    if (response.bodyBytes.isNotEmpty) {
      try {
        // JSON is UTF-8 whatever the content type says.
        json = jsonDecode(
          utf8.decode(response.bodyBytes, allowMalformed: true),
        );
      } catch (_) {
        json = null;
      }
    }
    if (status >= 200 && status < 300) return json;
    final detail = _detail(json);
    switch (status) {
      case 401:
        throw TaskSourceFailure(
          'auth',
          '$service refused the token (401). Check it and its expiry.',
        );
      case 403:
        throw TaskSourceFailure(
          'auth',
          '$service: not allowed (403)${detail == null ? '' : ': $detail'}.',
        );
      case 404:
        throw TaskSourceFailure(
          'not-found',
          '$service: not found (404)${detail == null ? '' : ': $detail'}.',
        );
      default:
        throw TaskSourceFailure(
          'failed',
          '$service answered $status${detail == null ? '' : ': $detail'}.',
        );
    }
  }

  static bool _isLocal(Uri uri) =>
      uri.scheme == 'http' &&
      (uri.host == 'localhost' || uri.host == '127.0.0.1');

  /// A short reason from an error body (GitHub `message`, Jira
  /// `errorMessages`, GraphQL `errors`, Azure `message`).
  static String? _detail(Object? json) {
    String? text;
    if (json is Map) {
      final message = json['message'] ?? json['error_description'];
      if (message is String) {
        text = message;
      } else if (json['errorMessages'] case final List<Object?> list
          when list.isNotEmpty) {
        text = list.join('; ');
      } else if (json['errors'] case final List<Object?> list
          when list.isNotEmpty && list.first is Map) {
        text = '${(list.first! as Map)['message']}';
      } else if (json['error'] is String) {
        text = json['error'] as String;
      }
    }
    if (text == null) return null;
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}

/// A trimmed base URL without its trailing slash, or [fallback].
String baseUrl(String? raw, String fallback) {
  final v = (raw ?? '').trim();
  final base = v.isEmpty ? fallback : v;
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
}

/// `base` plus path segments, each encoded.
Uri joinUri(String base, List<String> segments, [Map<String, String>? query]) {
  final uri = Uri.parse(base);
  return uri.replace(
    pathSegments: [...uri.pathSegments.where((s) => s.isNotEmpty), ...segments],
    queryParameters: query == null || query.isEmpty ? null : query,
  );
}

DateTime? parseTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String? str(Object? value) => value is String ? value : null;

/// Plain text from simple HTML (Azure Boards descriptions).
String htmlToText(String html) => html
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'</(p|div|li|h\d)>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '- ')
    .replaceAll(RegExp('<[^>]+>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();
