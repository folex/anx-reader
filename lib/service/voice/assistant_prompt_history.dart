import 'package:langchain_core/chat_models.dart';

/// Bound only the model's working context. The complete saved chat is untouched.
/// This is a recent-message window, not an invented summary of older exchanges.
List<ChatMessage> assistantPromptHistory(
  List<ChatMessage> messages, {
  required bool reusePrevious,
  int maxMessages = 13,
  int maxCharacters = 16000,
}) {
  if (messages.isEmpty) return [];
  if (!reusePrevious) return [messages.last];
  var start = messages.length - 1;
  var characters = messages.last.contentAsString.length;
  while (start > 0 && messages.length - start < maxMessages) {
    final next = messages[start - 1].contentAsString.length;
    if (characters + next > maxCharacters) break;
    start--;
    characters += next;
  }
  // Never start a retained exchange with an orphan assistant answer.
  while (start < messages.length - 1 && messages[start] is AIChatMessage)
    start++;
  return messages.sublist(start);
}
