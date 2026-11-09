import 'dart:convert';

import 'package:anx_reader/service/chatgpt/protocol.dart';

class ChatGptToolBinding {
  const ChatGptToolBinding({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  final String name, description;
  final Map<String, dynamic> parameters;
  final Future<String> Function(Map<String, dynamic>) execute;

  Map<String, dynamic> get specification => {
        'type': 'function',
        'name': name,
        'description': description,
        'parameters': parameters,
        'strict': false,
      };
}

typedef ChatGptToolRequest = Stream<Map<String, dynamic>> Function(
  List<Map<String, dynamic>> input,
  List<Map<String, dynamic>> tools,
);

/// A bounded, per-request loop. Reasoning/tool protocol items stay transient;
/// only visible final-answer text reaches the reader's history or speech engine.
Stream<String> chatGptToolLoop({
  required List<Map<String, dynamic>> initialInput,
  required List<ChatGptToolBinding> tools,
  required ChatGptToolRequest request,
  required bool Function() isCurrent,
  int maxRounds = 5,
  int maxCalls = 32,
}) async* {
  void guard() {
    if (!isCurrent())
      throw const ChatGptError(
        'The book, account, or request changed. Operation canceled.',
      );
  }

  final input = initialInput.map((x) => Map<String, dynamic>.from(x)).toList();
  final bindings = {for (final tool in tools) tool.name: tool};
  final specs = tools.map((x) => x.specification).toList();
  final executed = <String, ({String signature, String result})>{};
  var calls = 0;
  var argumentBytes = 0;
  var visible = '';
  for (var round = 0; round < maxRounds; round++) {
    guard();
    Map<String, dynamic>? completed;
    final items = <String, Map<String, dynamic>>{};
    var retainedItemBytes = 0;
    var roundText = '';
    await for (final event in request(input, specs)) {
      guard();
      switch (event['type']) {
        case 'response.output_text.delta':
          final delta = event['delta'];
          if (delta is String) {
            roundText += delta;
            if (visible.length + roundText.length > 64000)
              throw const ChatGptError('Response is too long.');
            yield visible + roundText;
          }
        case 'response.output_item.done':
          final item = event['item'];
          if (item is Map && item['id'] is String) {
            final encodedSize = utf8.encode(jsonEncode(item)).length;
            final previous = items[item['id']];
            final previousSize =
                previous == null ? 0 : utf8.encode(jsonEncode(previous)).length;
            retainedItemBytes += encodedSize - previousSize;
            if (retainedItemBytes > 2 * 1024 * 1024 ||
                previous == null && items.length >= 256) {
              throw const ChatGptError(
                'Tool response is too large.',
              );
            }
            items[item['id'] as String] = Map<String, dynamic>.from(item);
          }
        case 'response.completed':
          final value = event['response'];
          completed = value is Map
              ? Map<String, dynamic>.from(value)
              : <String, dynamic>{};
        case 'response.failed':
          throw chatGptApiError(event['response']);
        case 'response.incomplete':
          throw const ChatGptError(
            'ChatGPT did not finish the response. Try again.',
          );
        case 'error':
          throw chatGptApiError({'error': event});
      }
    }
    guard();
    if (completed == null)
      throw const ChatGptError(
          'Connection interrupted before the response completed.');
    final rawOutput = completed['output'];
    final output = rawOutput is List
        ? rawOutput
            .whereType<Map>()
            .map((x) => Map<String, dynamic>.from(x))
            .toList()
        : items.values.toList();
    if (output.length > 256 ||
        utf8.encode(jsonEncode(output)).length > 2 * 1024 * 1024) {
      throw const ChatGptError('Tool response is too large.');
    }
    if (roundText.isEmpty) {
      for (final message in output.where((x) => x['type'] == 'message')) {
        for (final part
            in (message['content'] as List? ?? []).whereType<Map>()) {
          if (part['type'] == 'output_text' && part['text'] is String) {
            roundText += part['text'] as String;
          }
        }
      }
      if (visible.length + roundText.length > 64000)
        throw const ChatGptError('Response is too long.');
      if (roundText.isNotEmpty) yield visible + roundText;
    }
    visible += roundText;
    final requested =
        output.where((x) => x['type'] == 'function_call').toList();
    if (requested.isEmpty) {
      if (visible.trim().isEmpty && executed.isNotEmpty) {
        final results = executed.values.toList();
        final decoded = results.map((entry) {
          try {
            return jsonDecode(entry.result);
          } catch (_) {
            return null;
          }
        }).toList();
        final errors = decoded
            .whereType<Map>()
            .where((value) => value['status'] == 'error')
            .toList();
        final allOk =
            decoded.every((value) => value is Map && value['status'] == 'ok');
        var savedAnnotation = false;
        for (var i = 0; i < results.length; i++) {
          final name = results[i].signature.split('\n').first;
          final value = decoded[i];
          if (['add_book_footnote', 'add_book_ruby', 'add_book_highlight']
                  .contains(name) &&
              value is Map &&
              value['data'] is Map &&
              value['data']['changed'] is bool) {
            savedAnnotation = true;
          }
        }
        final fallback = errors.isNotEmpty
            ? 'Reader actions could not all be completed. ${errors.map((value) => value['message'] ?? 'Check the saved changes before retrying.').join(' ')}'
            : allOk && savedAnnotation
                ? 'Reader annotations saved.'
                : results.map((entry) => entry.result).join('\n');
        yield fallback.substring(0, fallback.length.clamp(0, 64000));
      }
      return;
    }
    // store:false requires replaying every output item in order, including
    // opaque encrypted reasoning. Never persist or expose those items as text.
    input.addAll(output);
    if (roundText.isNotEmpty) visible += '\n';
    for (final call in requested) {
      guard();
      final id = call['call_id'];
      final name = call['name'];
      final arguments = call['arguments'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 200 ||
          name is! String ||
          arguments is! String ||
          utf8.encode(arguments).length > 128 * 1024) {
        throw const ChatGptError('Invalid tool call.');
      }
      final signature = '$name\n$arguments';
      final prior = executed[id];
      String result;
      if (prior != null) {
        if (prior.signature != signature)
          throw const ChatGptError(
            'Repeated tool call changed its arguments.',
          );
        result = prior.result;
      } else {
        if (++calls > maxCalls)
          throw const ChatGptError(
            'Edit limit reached for this request.',
          );
        argumentBytes += utf8.encode(arguments).length;
        if (argumentBytes > 1024 * 1024)
          throw const ChatGptError(
            'Too many tool arguments in one request.',
          );
        final binding = bindings[name];
        try {
          if (binding == null)
            throw const FormatException('Unknown or unavailable tool');
          final parsed = jsonDecode(arguments);
          if (parsed is! Map<String, dynamic>)
            throw const FormatException('Expected an object');
          guard();
          result = await binding.execute(parsed);
          guard();
          if (utf8.encode(result).length > 128 * 1024)
            throw const FormatException('Tool result too large');
        } on ChatGptError {
          rethrow;
        } on FormatException catch (error) {
          result = jsonEncode({'status': 'error', 'message': error.message});
        } catch (_) {
          result = jsonEncode({
            'status': 'error',
            'message': 'Could not complete the book edit.',
          });
        }
        executed[id] = (signature: signature, result: result);
      }
      input.add({
        'type': 'function_call_output',
        'call_id': id,
        'output': result,
      });
    }
  }
  throw const ChatGptError(
    'Step limit reached. Saved changes are intact.',
  );
}
