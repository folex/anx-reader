import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/protocol.dart';
import 'package:anx_reader/service/chatgpt/responses_socket.dart';
import 'package:anx_reader/service/reader_edits/chatgpt_tool_loop.dart';

const user = {'role': 'user', 'content': 'Annotate this paragraph'};
const options = {'model': 'test', 'instructions': 'Tutor'};
const function = {
  'type': 'function_call',
  'id': 'fc_1',
  'call_id': 'call_1',
  'name': 'edit',
  'arguments': '{}'
};
const reasoning = {
  'type': 'reasoning',
  'id': 'rs_1',
  'encrypted_content': 'opaque'
};
const result = {
  'type': 'function_call_output',
  'call_id': 'call_1',
  'output': 'saved'
};
Map<String, dynamic> completed(String id, List<dynamic> output) => {
      'type': 'response.completed',
      'response': {'id': id, 'output': output},
    };

void main() {
  late HttpServer server;
  late ChatGptResponsesSocket client;
  final sockets = <WebSocket>[];
  final requests = <Map<String, dynamic>>[];
  late Future<void> Function(WebSocket, Map<String, dynamic>) respond;
  var current = true;
  var connections = 0;
  setUp(() async {
    current = true;
    connections = 0;
    sockets.clear();
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test-only');
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      connections++;
      socket.listen((frame) async {
        final value = jsonDecode(frame as String) as Map<String, dynamic>;
        requests.add(value);
        await respond(socket, value);
      });
    });
    client = ChatGptResponsesSocket(
      connect: () => WebSocket.connect(
          'ws://127.0.0.1:${server.port}/v1/responses',
          headers: {'authorization': 'Bearer test-only'}),
      isCurrent: () => current,
    );
  });
  tearDown(() async {
    client.close();
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    await server.close(force: true);
  });
  test('one socket continues with only tool outputs and completes without EOF',
      () async {
    respond = (socket, request) async {
      socket.add(jsonEncode(completed('resp_${requests.length}',
          requests.length == 1 ? [reasoning, function] : [])));
    };
    await client.send([user], options).toList();
    await client.send([user, reasoning, function, result], options).toList();
    expect(connections, 1);
    expect(requests.first['type'], 'response.create');
    expect(requests.first['store'], false);
    expect(requests.first.containsKey('stream'), false);
    expect(requests.last['previous_response_id'], 'resp_1');
    expect(requests.last['input'], [result]);
  });
  test('changed input or options starts a fresh chain without cached history',
      () async {
    respond = (socket, _) async {
      socket.add(jsonEncode(completed('resp_${requests.length}', [])));
    };
    await client.send([user], options).toList();
    await client.send([
      {'role': 'user', 'content': 'Different book'}
    ], options).toList();
    expect(requests.last.containsKey('previous_response_id'), false);
    await client.send([
      {'role': 'user', 'content': 'Different book'},
      user
    ], {
      ...options,
      'instructions': 'Changed'
    }).toList();
    expect(requests.last.containsKey('previous_response_id'), false);
  });
  test(
      'missing connection cache retries full transcript once on the same socket',
      () async {
    respond = (socket, _) async {
      socket.add(jsonEncode(requests.length == 2
          ? {
              'type': 'error',
              'error': {'code': 'previous_response_not_found'}
            }
          : completed('resp_${requests.length}',
              requests.length == 1 ? [reasoning, function] : [])));
    };
    await client.send([user], options).toList();
    await client.send([user, reasoning, function, result], options).toList();
    expect(connections, 1);
    expect(requests.length, 3);
    expect(requests.last.containsKey('previous_response_id'), false);
    expect(requests.last['input'], [user, reasoning, function, result]);
  });
  test('cache failure recovery is bounded and does not hide server errors',
      () async {
    respond = (socket, _) async {
      socket.add(jsonEncode(requests.length == 1
          ? completed('resp_1', [])
          : {
              'type': 'error',
              'error': {'code': 'previous_response_not_found'}
            }));
    };
    await client.send([user], options).toList();
    final events = await client.send([user, user], options).toList();
    expect(requests.length, 3);
    expect(events.single['type'], 'error');
  });
  test('socket EOF reconnects with full history without repeating a saved edit',
      () async {
    var executions = 0;
    respond = (socket, _) async {
      if (requests.length == 1) {
        socket.add(jsonEncode(completed('resp_1', [reasoning, function])));
      } else if (requests.length == 2) {
        await socket.close();
      } else {
        socket.add(jsonEncode(
            {'type': 'response.output_text.delta', 'delta': 'Done'}));
        socket.add(jsonEncode(completed('resp_3', [])));
      }
    };
    final text = await chatGptToolLoop(
        initialInput: [
          user
        ],
        tools: [
          ChatGptToolBinding(
              name: 'edit',
              description: 'edit',
              parameters: {},
              execute: (_) async {
                executions++;
                return 'saved';
              })
        ],
        request: (input, _) => client.send(input, options),
        isCurrent: () => current).toList();
    expect(text.last, 'Done');
    expect(executions, 1);
    expect(connections, 2);
    expect(requests.last.containsKey('previous_response_id'), false);
    expect(requests.last['input'], [user, reasoning, function, result]);
  });
  test('cancel closes upgraded socket and prevents subsequent sends', () async {
    final received = Completer<void>();
    respond = (_, __) async {
      received.complete();
    };
    final pending = client.send([user], options).toList();
    final rejection = expectLater(pending, throwsA(isA<ChatGptError>()));
    await received.future;
    client.close();
    await rejection;
    await expectLater(
        client.send([user], options).toList(), throwsA(isA<ChatGptError>()));
    expect(requests.length, 1);
  });
  test('upgrade finishing after cancellation closes the late socket', () async {
    client.close();
    final pending = Completer<WebSocket>();
    final started = Completer<void>();
    client = ChatGptResponsesSocket(
        connect: () {
          started.complete();
          return pending.future;
        },
        isCurrent: () => current);
    final rejection = expectLater(
        client.send([user], options).toList(), throwsA(isA<ChatGptError>()));
    await started.future;
    client.close();
    final late = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/v1/responses',
        headers: {'authorization': 'Bearer test-only'});
    pending.complete(late);
    await rejection;
    await late.done.timeout(const Duration(seconds: 3));
    expect(requests, isEmpty);
  });
  test('nested WebSocket errors retain their safe code', () async {
    respond = (socket, _) async {
      socket.add(jsonEncode({
        'type': 'error',
        'error': {
          'code': 'subscription_sharing_usage_limit_exceeded',
          'message': 'raw secret'
        }
      }));
    };
    await expectLater(
        chatGptText(client.send([user], options)).toList(),
        throwsA(isA<ChatGptError>().having((e) => e.message, 'safe message',
            'ChatGPT subscription limit reached. Try later.')));
    expect(requests.length, 1);
  });
  test('timed out upgrade closes a socket that arrives later', () async {
    client.close();
    final pending = Completer<WebSocket>();
    client = ChatGptResponsesSocket(
        connect: () => pending.future,
        isCurrent: () => current,
        connectTimeout: const Duration(milliseconds: 10));
    await expectLater(
        client.send([user], options).toList(), throwsA(isA<SocketException>()));
    final late = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/v1/responses',
        headers: {'authorization': 'Bearer test-only'});
    pending.complete(late);
    await late.done.timeout(const Duration(seconds: 3));
    expect(requests, isEmpty);
  });
  test('scope change rejects the response before tools can see it', () async {
    respond = (socket, _) async {
      current = false;
      socket.add(jsonEncode(completed('resp_1', [function])));
    };
    await expectLater(
        client.send([user], options).toList(), throwsA(isA<ChatGptError>()));
  });
}
