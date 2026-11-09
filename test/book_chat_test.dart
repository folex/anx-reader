import 'dart:async';
import 'dart:io';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/current_reading_state.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/providers/ai_history.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/service/ai/ai_history.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_test.dart' as fixture;

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
}

// Actual Riverpod reads with a lightweight WidgetRef adapter; no widget fake
// scheduler is needed for these real filesystem and stream interleavings.
class _Ref extends Fake implements WidgetRef {
  _Ref(this.container);
  final ProviderContainer container;
  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

class _BlockNetwork extends HttpOverrides {
  int requests = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('Network must not run for a stale chat.');
  }
}

class _DelayedHistory extends AiHistoryNotifier {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> upsert(AiChatHistoryEntry entry) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ChatGptPlan plan;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'anx-chatgpt-history-test-',
    );
    PathProviderPlatform.instance = _Paths(directory.path);
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    plan = ChatGptPlan.testClient(
      records: [
        fixture.record('A', expired: false),
        fixture.record('B', expired: false),
      ],
      transport: (url, bearer, form) async => {'models': []},
    );
    ChatGptPlan.setTestInstance(plan);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  CurrentReadingState reading(int id) =>
      CurrentReadingState(isReading: true, book: Book.mock().copyWith(id: id));
  AiChatHistoryEntry entry(String id, String text) => AiChatHistoryEntry(
    id: id,
    serviceId: 'chatgpt_plan',
    model: 'test',
    createdAt: 1,
    updatedAt: 1,
    messages: [ChatMessage.humanText(text)],
    completed: true,
  );
  test(
    'reopen restores one history per book and account without borrowing another',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(aiChatProvider.future);
      final chat = container.read(aiChatProvider.notifier);
      final accountA = plan.active!.id;
      await AiHistoryStore.upsertEntry(
        entry('chatgpt:$accountA:book:1', 'Book one'),
      );
      await AiHistoryStore.upsertEntry(
        entry('chatgpt:$accountA:book:2', 'Book two'),
      );
      container.read(currentReadingProvider.notifier).start(reading(1));
      await chat.prepareBookChat();
      expect(
        container.read(aiChatProvider).value!.single.contentAsString,
        'Book one',
      );
      container.read(currentReadingProvider.notifier).start(reading(2));
      await Future.wait([chat.prepareBookChat(), chat.prepareBookChat()]);
      expect(
        container.read(aiChatProvider).value!.single.contentAsString,
        'Book two',
      );
      await plan.selectAccount(plan.accounts.last.id);
      await chat.prepareBookChat();
      expect(container.read(aiChatProvider).value, isEmpty);
      await plan.selectAccount(accountA);
      await chat.prepareBookChat();
      expect(
        container.read(aiChatProvider).value!.single.contentAsString,
        'Book two',
      );
      chat.restore([ChatMessage.humanText('temp')]);
      expect(chat.currentSessionId, isNull);
    },
  );
  test(
    'account switch during context fetch performs zero inference requests',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = _Ref(container);
      container.read(currentReadingProvider.notifier).start(reading(1));
      final entered = Completer<void>();
      final result = Completer<String>();
      container
          .read(chapterContentBridgeProvider.notifier)
          .state = ChapterContentHandlers(
        fetchCurrentChapter: ({maxCharacters}) {
          entered.complete();
          return result.future;
        },
        fetchChapterByHref: (_, {maxCharacters}) async => '',
      );
      final network = _BlockNetwork();
      await HttpOverrides.runWithHttpOverrides(() async {
        final streamResult = expectLater(
          aiGenerateStream(
            [ChatMessage.humanText('quoted passage long enough')],
            useAgent: true,
            ref: ref,
          ).toList(),
          throwsA(anything),
        );
        await entered.future.timeout(const Duration(seconds: 5));
        await plan.selectAccount(plan.accounts.last.id);
        result.complete('quoted passage long enough');
        await streamResult;
        expect(network.requests, 0);
      }, network);
    },
  );
  test(
    'cancel during context fetch performs zero inference requests',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ref = _Ref(container);
      container.read(currentReadingProvider.notifier).start(reading(1));
      final entered = Completer<void>();
      final result = Completer<String>();
      container
          .read(chapterContentBridgeProvider.notifier)
          .state = ChapterContentHandlers(
        fetchCurrentChapter: ({maxCharacters}) {
          entered.complete();
          return result.future;
        },
        fetchChapterByHref: (_, {maxCharacters}) async => '',
      );
      final network = _BlockNetwork();
      await HttpOverrides.runWithHttpOverrides(() async {
        final streamResult = expectLater(
          aiGenerateStream(
            [ChatMessage.humanText('quoted passage long enough')],
            useAgent: true,
            ref: ref,
          ).toList(),
          throwsA(anything),
        );
        await entered.future.timeout(const Duration(seconds: 5));
        cancelActiveAiRequest();
        result.complete('quoted passage long enough');
        await streamResult;
        expect(network.requests, 0);
      }, network);
    },
  );
  test(
    'book switch while draft persistence waits performs zero inference requests',
    () async {
      final history = _DelayedHistory();
      final container = ProviderContainer(
        overrides: [aiHistoryProvider.overrideWith((ref) => history)],
      );
      addTearDown(container.dispose);
      final ref = _Ref(container);
      container.read(currentReadingProvider.notifier).start(reading(1));
      await container.read(aiChatProvider.future);
      final chat = container.read(aiChatProvider.notifier);
      await chat.prepareBookChat();
      final network = _BlockNetwork();
      await HttpOverrides.runWithHttpOverrides(() async {
        final result = chat
            .sendMessageStream('Book one question', ref, false)
            .toList();
        await history.entered.future.timeout(const Duration(seconds: 5));
        container.read(currentReadingProvider.notifier).start(reading(2));
        await chat.prepareBookChat();
        history.release.complete();
        expect(await result, isEmpty);
        expect(network.requests, 0);
        expect(chat.currentSessionId, endsWith(':book:2'));
      }, network);
    },
  );
}
