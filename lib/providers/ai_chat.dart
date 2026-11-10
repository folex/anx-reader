import 'package:anx_reader/service/voice/assistant_activity.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/providers/ai_history.dart';
import 'package:anx_reader/service/ai/ai_history.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:anx_reader/service/voice/assistant_prompt_history.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:langchain_core/chat_models.dart';

part 'ai_chat.g.dart';

@Riverpod(keepAlive: true)
class AiChat extends _$AiChat {
  String? _currentSessionId;
  int _conversationEpoch = 0;
  Future<void>? _bookPreparation;
  bool _turnActive = false;
  Object? _turnOwner;
  bool ownsTurn(Object owner) => _turnActive && identical(_turnOwner, owner);
  bool get isStreaming => _turnActive;
  int get conversationEpoch => _conversationEpoch;
  Future<void> ensureSessionForVoice() async {
    await prepareBookChat();
    _ensureSessionId();
  }

  Future<void> prepareBookChat() async {
    final plan = ChatGptPlan.instance;
    try {
      await plan.initialize();
    } catch (_) {
      if (plan.enabled) rethrow;
      return;
    }
    if (!plan.enabled || plan.active == null) {
      if (_currentSessionId?.startsWith("chatgpt:") == true) {
        _conversationEpoch++;
        _currentSessionId = null;
        state = const AsyncData([]);
      }
      return;
    }
    final reading = ref.read(currentReadingProvider);
    final key =
        "chatgpt:${plan.active!.id}:book:${reading.isReading ? reading.book?.id ?? 'general' : 'general'}";
    if (_currentSessionId == key) {
      await _bookPreparation;
      return;
    }
    final epoch = ++_conversationEpoch;
    _currentSessionId = key;
    state = const AsyncData([]);
    final preparation = () async {
      final history = await AiHistoryStore.readHistory();
      if (epoch != _conversationEpoch) return;
      final entry = history.where((e) => e.id == key).firstOrNull;
      state = AsyncData(List<ChatMessage>.from(entry?.messages ?? []));
    }();
    _bookPreparation = preparation;
    await preparation;
  }

  @override
  FutureOr<List<ChatMessage>> build() async {
    _currentSessionId = null;
    return List<ChatMessage>.empty();
  }

  Future<void> sendMessage(String message) async {
    state = AsyncData([
      ...state.whenOrNull(data: (data) => data) ?? [],
      ChatMessage.humanText(message),
    ]);
  }

  void restore(List<ChatMessage> history, {String? sessionId}) {
    _conversationEpoch++;
    _currentSessionId = sessionId;
    state = AsyncData(history);
  }

  Stream<List<ChatMessage>> sendMessageStream(
    String message,
    WidgetRef widgetRef,
    bool isRegenerate, {
    String? transientContext,
    Object? requestOwner,
    bool assistantMode = false,
    void Function(AssistantActivity)? onActivity,
  }) async* {
    if (_turnActive) throw StateError('Wait for the previous response.');
    _turnActive = true;
    _turnOwner = requestOwner;
    try {
      yield* _sendMessageStream(
        message,
        widgetRef,
        isRegenerate,
        transientContext: transientContext,
        assistantMode: assistantMode,
        onActivity: onActivity,
      );
    } finally {
      _turnOwner = null;
      _turnActive = false;
    }
  }

  Stream<List<ChatMessage>> _sendMessageStream(
    String message,
    WidgetRef widgetRef,
    bool isRegenerate, {
    String? transientContext,
    bool assistantMode = false,
    void Function(AssistantActivity)? onActivity,
  }) async* {
    final readingBefore = widgetRef.read(currentReadingProvider);
    await prepareBookChat();
    final readingAfter = widgetRef.read(currentReadingProvider);
    if (readingBefore.book?.id != readingAfter.book?.id ||
        readingBefore.isReading != readingAfter.isReading) {
      throw StateError('The book changed. Ask again in its chat.');
    }
    final epoch = _conversationEpoch;
    final expectedAccount = ChatGptPlan.instance.active?.id;
    final expectedEnabled = ChatGptPlan.instance.enabled;
    final sessionId = _ensureSessionId();
    final plan = ChatGptPlan.instance;
    final serviceId = plan.enabled
        ? ChatGptPlan.providerId
        : Prefs().selectedAiService;
    final config = Prefs().getAiConfig(serviceId);
    final model = plan.enabled
        ? plan.active?.model ?? ''
        : (config['model'])?.trim() ?? '';
    final historyNotifier = widgetRef.read(aiHistoryProvider.notifier);
    final initialHistoryState = widgetRef
        .read(aiHistoryProvider)
        .maybeWhen(data: (value) => value, orElse: () => const []);
    AiChatHistoryEntry? entry;
    for (final item in initialHistoryState) {
      if (item.id == sessionId) {
        entry = item;
        break;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;

    List<ChatMessage> messages = [
      ...state.whenOrNull(data: (data) => data) ?? [],
      ChatMessage.humanText(message),
    ];

    state = AsyncData(messages);

    List<ChatMessage> updatedMessages = [...messages, ChatMessage.ai('')];

    final draftEntry =
        (entry ??
                AiChatHistoryEntry(
                  id: sessionId,
                  serviceId: serviceId,
                  model: model,
                  createdAt: entry?.createdAt ?? now,
                  updatedAt: now,
                  messages: List<ChatMessage>.from(updatedMessages),
                  completed: false,
                ))
            .copyWith(
              messages: List<ChatMessage>.from(updatedMessages),
              updatedAt: now,
              completed: false,
              model: model,
            );

    await historyNotifier.upsert(draftEntry);
    if (epoch != _conversationEpoch ||
        expectedAccount != plan.active?.id ||
        expectedEnabled != plan.enabled ||
        readingAfter.book?.id !=
            widgetRef.read(currentReadingProvider).book?.id ||
        readingAfter.isReading !=
            widgetRef.read(currentReadingProvider).isReading)
      return;

    yield updatedMessages;

    String assistantResponse = "";
    try {
      await for (final chunk in aiGenerateStream(
        [
          if (transientContext != null) ChatMessage.system(transientContext),
          ...(assistantMode
              ? assistantPromptHistory(messages,
                  reusePrevious: Prefs().assistantReusePreviousChat)
              : messages),
        ],
        regenerate: isRegenerate,
        useAgent: true,
        toolIdsOverride: assistantMode ? bookAssistantToolIds : null,
        onActivity: onActivity,
        ref: widgetRef,
      )) {
        if (epoch != _conversationEpoch) return;
        assistantResponse = chunk;

        final updatedMessagesWithResponse = List<ChatMessage>.from(
          updatedMessages,
        );
        updatedMessagesWithResponse[updatedMessagesWithResponse.length - 1] =
            assistantMessageFromDisplayContent(assistantResponse);

        yield updatedMessagesWithResponse;

        state = AsyncData(updatedMessagesWithResponse);
      }
      if (epoch != _conversationEpoch) return;
      final completedEntry = draftEntry.copyWith(
        messages: List<ChatMessage>.from(state.value ?? updatedMessages),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        completed: true,
        model: model,
      );
      await historyNotifier.upsert(completedEntry);
    } catch (_) {
      if (epoch != _conversationEpoch) return;
      final failedEntry = draftEntry.copyWith(
        messages: List<ChatMessage>.from(state.value ?? updatedMessages),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        completed: false,
        model: model,
      );
      await historyNotifier.upsert(failedEntry);
      rethrow;
    }
  }

  void clear() {
    _conversationEpoch++;
    state = AsyncData(List<ChatMessage>.empty());
    _currentSessionId = null;
  }

  void loadHistoryEntry(AiChatHistoryEntry entry) {
    _conversationEpoch++;
    _currentSessionId = entry.id;
    state = AsyncData(List<ChatMessage>.from(entry.messages));
  }

  String? get currentSessionId => _currentSessionId;

  String _ensureSessionId() {
    return _currentSessionId ??= _generateSessionId();
  }

  String _generateSessionId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }
}
