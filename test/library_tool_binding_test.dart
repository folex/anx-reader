import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/service/reader_edits/chatgpt_tool_loop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_test.dart' show record;

class InspectPlan extends ChatGptPlan {
  InspectPlan() : super.testClient(
    records: [record('library', expired: false)],
    transport: (_, __, ___) async => {},
  );
  List<ChatGptToolBinding> captured = [];
  @override
  Stream<String> generate(List<ChatMessage> messages, {
    String? readingContext, String? expectedAccountId,
    int? expectedRequestRevision, List<ChatGptToolBinding> tools = const [],
    bool Function()? toolScopeCurrent,
  }) async* {
    expect(toolScopeCurrent?.call(), true);
    captured = tools;
    yield 'Ready';
  }
}

void main() {
  testWidgets('ChatGPT receives library tools with no book open or edit bridge', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    final plan = InspectPlan();
    final original = ChatGptPlan.instance;
    ChatGptPlan.setTestInstance(plan);
    addTearDown(() => ChatGptPlan.setTestInstance(original));
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(child: Consumer(builder: (context, value, child) {
      ref = value;
      return const SizedBox();
    })));
    final output = await aiGenerateStream(
      [ChatMessage.humanText('Search all books for ira')],
      useAgent: true, ref: ref,
    ).toList();
    expect(output, ['Ready']);
    expect(plan.captured.map((tool) => tool.name), unorderedEquals(libraryBookToolIds));
    expect(plan.captured.map((tool) => tool.name), isNot(contains('add_book_ruby')));
  });
}
