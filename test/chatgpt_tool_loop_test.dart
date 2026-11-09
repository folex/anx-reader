import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/protocol.dart';
import 'package:anx_reader/service/reader_edits/chatgpt_tool_loop.dart';

Map<String, dynamic> call(
  String id, {
  String name = 'add_book_footnote',
  String args = '{"quote":"ira"}',
}) =>
    {
      'type': 'function_call',
      'id': 'fc_$id',
      'call_id': id,
      'name': name,
      'arguments': args,
    };
Map<String, dynamic> message(String text) => {
      'type': 'message',
      'id': 'msg_1',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    };
Stream<Map<String, dynamic>> complete(
  List<Map<String, dynamic>> output, {
  String? delta,
}) async* {
  if (delta != null)
    yield {'type': 'response.output_text.delta', 'delta': delta};
  yield {
    'type': 'response.completed',
    'response': {'status': 'completed', 'output': output},
  };
}

ChatGptToolBinding binding(Future<String> Function(Map<String, dynamic>) run) =>
    ChatGptToolBinding(
      name: 'add_book_footnote',
      description: 'Add an exact anchored note',
      parameters: {
        'type': 'object',
        'properties': {
          'quote': {'type': 'string'},
        },
        'required': ['quote'],
      },
      execute: run,
    );

void main() {
  test(
      'successful saved annotations get a confirmation when model final text is empty',
      () async {
    var round = 0;
    final output = await chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async => '{"status":"ok","data":{"changed":true}}')
        ],
        isCurrent: () => true,
        request: (_, __) =>
            round++ == 0 ? complete([call('saved')]) : complete([])).toList();
    expect(output.last, 'Reader annotations saved.');
  });
  test('an empty final answer never turns a failed edit into success',
      () async {
    var round = 0;
    final output = await chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async =>
              '{"status":"error","message":"Exact phrase not found"}')
        ],
        isCurrent: () => true,
        request: (_, __) =>
            round++ == 0 ? complete([call('failed')]) : complete([])).toList();
    expect(output.last, contains('Exact phrase not found'));
    expect(output.last, isNot(contains('annotations saved')));
  });

  test(
    'call executes once, replays opaque reasoning and result, streams final answer',
    () async {
      final initial = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'Explain ira'},
      ];
      final reasoning = <String, dynamic>{
        'type': 'reasoning',
        'id': 'rs1',
        'encrypted_content': 'opaque-private-data',
        'summary': [],
      };
      var rounds = 0, executions = 0;
      final result = await chatGptToolLoop(
        initialInput: initial,
        tools: [
          binding((args) async {
            executions++;
            expect(args['quote'], 'ira');
            return '{"status":"ok"}';
          }),
        ],
        isCurrent: () => true,
        request: (input, specs) {
          expect(specs.single['type'], 'function');
          expect(specs.single['name'], 'add_book_footnote');
          if (rounds++ == 0) return complete([reasoning, call('c1')]);
          expect(input[1], reasoning);
          expect(input[2]['call_id'], 'c1');
          expect(input.last, {
            'type': 'function_call_output',
            'call_id': 'c1',
            'output': '{"status":"ok"}',
          });
          return complete([message('Готово')], delta: 'Готово');
        },
      ).toList();
      expect(result.last, 'Готово');
      expect(result.join(), isNot(contains('opaque-private-data')));
      expect(executions, 1);
      expect(rounds, 2);
      expect(initial.length, 1);
    },
  );

  test(
    'unknown tool and malformed JSON return errors without invoking a mutation',
    () async {
      var round = 0, executions = 0;
      await chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async {
            executions++;
            return 'ok';
          }),
        ],
        isCurrent: () => true,
        request: (input, _) {
          if (round++ == 0)
            return complete([
              call('bad1', name: 'run_arbitrary_code'),
              call('bad2', args: 'not JSON'),
              call('bad3', args: '[]'),
            ]);
          final errors = input.where(
            (x) => x['type'] == 'function_call_output',
          );
          expect(errors.length, 3);
          expect(
            errors.every(
              (x) => jsonDecode(x['output'] as String)['status'] == 'error',
            ),
            true,
          );
          return complete([message('Не получилось')]);
        },
      ).drain<void>();
      expect(executions, 0);
    },
  );

  test('identical duplicate call id reuses result across rounds', () async {
    var round = 0, executions = 0;
    await chatGptToolLoop(
      initialInput: [],
      tools: [
        binding((_) async {
          executions++;
          return 'saved';
        }),
      ],
      isCurrent: () => true,
      request: (input, _) => round++ < 2
          ? complete([call('same')])
          : complete([message('Готово')]),
    ).drain<void>();
    expect(executions, 1);
  });

  test(
    'same call id with changed parameters is rejected without second write',
    () async {
      var round = 0, executions = 0;
      final stream = chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async {
            executions++;
            return 'ok';
          }),
        ],
        isCurrent: () => true,
        request: (_, __) => complete([
          call(
            'same',
            args: round++ == 0 ? '{"quote":"ira"}' : '{"quote":"amor"}',
          ),
        ]),
      );
      await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
      expect(executions, 1);
    },
  );

  test(
    'incomplete or interrupted responses never execute pending function calls',
    () async {
      for (final eventType in [
        'response.incomplete',
        'response.failed',
        'error',
        'eof',
      ]) {
        var executions = 0;
        final stream = chatGptToolLoop(
          initialInput: [],
          tools: [
            binding((_) async {
              executions++;
              return 'ok';
            }),
          ],
          isCurrent: () => true,
          request: (_, __) async* {
            yield {'type': 'response.output_item.done', 'item': call('c1')};
            if (eventType != 'eof')
              yield {
                'type': eventType,
                'response': {
                  'error': {'message': 'fixture failure'},
                },
              };
          },
        );
        await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
        expect(executions, 0, reason: eventType);
      }
    },
  );

  test('scope change while receiving response prevents execution', () async {
    var current = true, executions = 0;
    final stream = chatGptToolLoop(
      initialInput: [],
      tools: [
        binding((_) async {
          executions++;
          return 'ok';
        }),
      ],
      isCurrent: () => current,
      request: (_, __) async* {
        current = false;
        yield {
          'type': 'response.completed',
          'response': {
            'output': [call('c1')],
          },
        };
      },
    );
    await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
    expect(executions, 0);
  });

  test(
    'scope change during a tool prevents result replay and next request',
    () async {
      var current = true, rounds = 0, executions = 0;
      final stream = chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async {
            executions++;
            current = false;
            return 'saved before scope changed';
          }),
        ],
        isCurrent: () => current,
        request: (_, __) {
          rounds++;
          return complete([call('c1')]);
        },
      );
      await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
      expect(executions, 1);
      expect(rounds, 1);
    },
  );

  test('call and round limits bound repeated mutations', () async {
    var executions = 0;
    var stream = chatGptToolLoop(
      initialInput: [],
      tools: [
        binding((_) async {
          executions++;
          return 'ok';
        }),
      ],
      isCurrent: () => true,
      maxCalls: 1,
      request: (_, __) => complete([call('a'), call('b')]),
    );
    await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
    expect(executions, 1);
    var rounds = 0;
    executions = 0;
    stream = chatGptToolLoop(
      initialInput: [],
      tools: [
        binding((_) async {
          executions++;
          return 'ok';
        }),
      ],
      isCurrent: () => true,
      maxRounds: 2,
      request: (_, __) => complete([call('c${rounds++}')]),
    );
    await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
    expect(rounds, 2);
    expect(executions, 2);
  });

  test(
    'text-only completed output is returned even without deltas or tools',
    () async {
      final text = await chatGptToolLoop(
        initialInput: [],
        tools: [],
        isCurrent: () => true,
        request: (_, specs) {
          expect(specs, isEmpty);
          return complete([message('Обычный ответ')]);
        },
      ).toList();
      expect(text, ['Обычный ответ']);
    },
  );

  test(
    'ten calls in one response execute sequentially, duplicate call replays',
    () async {
      var rounds = 0, active = 0, maxActive = 0;
      final seen = <int>[];
      final result = await chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((args) async {
            active++;
            if (active > maxActive) maxActive = active;
            await Future<void>.delayed(Duration.zero);
            seen.add(args['index'] as int);
            active--;
            return 'ok';
          }),
        ],
        isCurrent: () => true,
        request: (input, _) {
          if (rounds++ == 0)
            return complete([
              for (var i = 0; i < 10; i++)
                call('c$i', args: jsonEncode({'index': i})),
              call('c0', args: '{"index":0}'),
            ]);
          expect(
            input
                .where((item) => item['type'] == 'function_call_output')
                .length,
            11,
          );
          return complete([message('Готово')]);
        },
      ).toList();
      expect(seen, List.generate(10, (i) => i));
      expect(maxActive, 1);
      expect(result.last, 'Готово');
    },
  );
  test(
    'batch-sized valid JSON arguments exceed old16KiB and execute',
    () async {
      var rounds = 0, executions = 0;
      await chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async {
            executions++;
            return 'ok';
          }),
        ],
        isCurrent: () => true,
        request: (_, __) => rounds++ == 0
            ? complete([
                call('batch', args: jsonEncode({'text': 'я' * 20000})),
              ])
            : complete([message('ok')]),
      ).toList();
      expect(executions, 1);
    },
  );
  test('aggregate argument budget stays bounded over multiple calls', () async {
    var executions = 0;
    final args = jsonEncode({'text': 'x' * 120000});
    await expectLater(
      chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async {
            executions++;
            return 'ok';
          }),
        ],
        isCurrent: () => true,
        request: (_, __) =>
            complete([for (var i = 0; i < 10; i++) call('b$i', args: args)]),
      ).toList(),
      throwsA(isA<ChatGptError>()),
    );
    expect(executions, 8);
  });
  test(
    '80KiB batch result is replayed, result beyond128KiB is bounded',
    () async {
      for (final size in [80 * 1024, 128 * 1024 + 1]) {
        var rounds = 0;
        await chatGptToolLoop(
          initialInput: [],
          tools: [binding((_) async => 'x' * size)],
          isCurrent: () => true,
          request: (input, _) {
            if (rounds++ == 0) return complete([call('result')]);
            final output = input.last['output'] as String;
            if (size <= 128 * 1024) {
              expect(output.length, size);
            } else {
              expect(jsonDecode(output)['message'], 'Tool result too large');
            }
            return complete([message('done')]);
          },
        ).toList();
      }
    },
  );
  test('oversized tool arguments cannot execute', () async {
    var executions = 0;
    final stream = chatGptToolLoop(
      initialInput: [],
      tools: [
        binding((_) async {
          executions++;
          return 'ok';
        }),
      ],
      isCurrent: () => true,
      request: (_, __) =>
          complete([call('large', args: 'x' * (128 * 1024 + 1))]),
    );
    await expectLater(stream.toList(), throwsA(isA<ChatGptError>()));
    expect(executions, 0);
  });

  test(
    'completed-only fallback text obeys the same answer size limit as deltas',
    () async {
      final stream = chatGptToolLoop(
        initialInput: [],
        tools: [],
        isCurrent: () => true,
        request: (_, __) => complete([message('x' * 64001)]),
      );
      await expectLater(stream.drain<void>(), throwsA(isA<ChatGptError>()));
    },
  );

  test(
    'answer size is bounded across tool rounds before a later mutation',
    () async {
      var rounds = 0, executions = 0;
      final stream = chatGptToolLoop(
        initialInput: [],
        tools: [
          binding((_) async {
            executions++;
            return 'ok';
          }),
        ],
        isCurrent: () => true,
        request: (_, __) {
          final round = rounds++;
          final text = 'x' * (round == 0 ? 50000 : 30000);
          return complete([message(text), call('c$round')], delta: text);
        },
      );
      await expectLater(stream.drain<void>(), throwsA(isA<ChatGptError>()));
      expect(rounds, 2);
      expect(executions, 1);
    },
  );
  test('output item bound applies before stream completion', () async {
    var completedSent = false;
    final stream = chatGptToolLoop(
      initialInput: [],
      tools: [],
      isCurrent: () => true,
      request: (_, __) async* {
        for (var i = 0; i < 257; i++) {
          yield {
            'type': 'response.output_item.done',
            'item': {
              'type': 'reasoning',
              'id': 'rs$i',
              'encrypted_content': 'opaque',
            },
          };
        }
        completedSent = true;
        yield {
          'type': 'response.completed',
          'response': {'status': 'completed'},
        };
      },
    );
    await expectLater(stream.drain<void>(), throwsA(isA<ChatGptError>()));
    expect(completedSent, false);
  });
}
