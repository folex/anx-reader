import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:anx_reader/service/voice/assistant_prompt_history.dart';

void main() {
  final history = <ChatMessage>[
    for (var i = 0; i < 30; i++) ...[
      ChatMessage.humanText('question $i'),
      ChatMessage.ai('answer $i')
    ],
    ChatMessage.humanText('current')
  ];
  test(
      'fresh question ignores previous conversation without modifying saved history',
      () {
    final prompt = assistantPromptHistory(history, reusePrevious: false);
    expect(prompt.map((m) => m.contentAsString), ['current']);
    expect(history.length, 61);
  });
  test(
      'recent context has bounded messages and starts with a complete exchange',
      () {
    final prompt = assistantPromptHistory(history, reusePrevious: true);
    expect(prompt.length, 13);
    expect(prompt.first, isA<HumanChatMessage>());
    expect(prompt.last.contentAsString, 'current');
    expect(history.length, 61);
  });
  test(
      'large old replies are omitted and the latest question is never truncated',
      () {
    final prompt = assistantPromptHistory([
      ChatMessage.humanText('old'),
      ChatMessage.ai('x' * 20000),
      ChatMessage.humanText('current')
    ], reusePrevious: true);
    expect(prompt.length, 1);
    expect(prompt.single.contentAsString, 'current');
  });
}
