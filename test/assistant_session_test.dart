import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/voice/assistant_session.dart';
import 'package:anx_reader/service/voice/assistant_tts.dart';
import 'package:anx_reader/service/voice/reader_voice.dart';
import 'package:anx_reader/service/chatgpt/protocol.dart';

class FakeNative implements ReaderVoiceNative, AssistantTtsNative {
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final calls = <Map<String, dynamic>>[];
  Future<void> Function(String, Map<String, dynamic>)? behavior;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<void> invoke(String method, Map<String, dynamic> arguments) async {
    calls.add({'method': method, ...arguments});
    await behavior?.call(method, arguments);
  }

  String id(String method) =>
      calls.lastWhere((c) => c['method'] == method)['id'] as String;
  int count(String method) => calls.where((c) => c['method'] == method).length;
  void event(String id, String type, {String? text, String? code}) =>
      controller.add({
        'id': id,
        'type': type,
        if (text != null) 'text': text,
        if (code != null) 'code': code,
      });
}

Future<void> drain() async {
  for (var i = 0; i < 8; i++) await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative speech, tts;
  late AssistantSession session;
  late List<String> questions;
  late String scope;
  late Completer<String> answer;
  late int cancels;
  setUp(() {
    speech = FakeNative();
    tts = FakeNative();
    questions = [];
    scope = 'book1-account1';
    answer = Completer<String>();
    cancels = 0;
    session = AssistantSession(
      speech: speech,
      tts: tts,
      currentScope: () => scope,
      sendQuestion: (q) {
        questions.add(q);
        return answer.future;
      },
      cancelQuestion: () {
        cancels++;
      },
      echoTail: Duration.zero,
    );
  });
  tearDown(() async {
    session.dispose();
    await drain();
    await speech.controller.close();
    await tts.controller.close();
  });
  test(
    'one final utterance produces one model turn and one TTS; rearm waits real completion',
    () async {
      await session.start();
      final id = speech.id('startAssistantListening');
      speech.event(id, 'partial', text: 'Что зна');
      expect(questions, isEmpty);
      expect(session.transcript, 'Что зна');
      speech.event(id, 'processing');
      expect(session.state, AssistantState.transcribing);
      speech.event(id, 'transcript', text: 'Что значит acostumbrare?');
      speech.event(id, 'transcript', text: 'duplicate');
      await drain();
      expect(questions, ['Что значит acostumbrare?']);
      expect(session.state, AssistantState.thinking);
      expect(speech.count('cancel'), 1);
      expect(tts.count('speak'), 0);
      answer.complete('**Привыкать** к чему-либо.');
      await drain();
      expect(session.state, AssistantState.speaking);
      expect(tts.count('speak'), 1);
      expect(tts.calls.last['text'], 'Привыкать к чему-либо.');
      expect(speech.count('startAssistantListening'), 1);
      final voiceId = tts.id('speak');
      tts.event(voiceId, 'started');
      await drain();
      expect(speech.count('startAssistantListening'), 1);
      tts.event(voiceId, 'completed');
      await drain();
      expect(speech.count('startAssistantListening'), 2);
      tts.event(voiceId, 'completed');
      await drain();
      expect(speech.count('startAssistantListening'), 2);
    },
  );
  test(
    'pause while thinking fences the late model result and cancels its request',
    () async {
      await session.start();
      speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Pregunta');
      await drain();
      await session.pause();
      answer.complete('Late answer');
      await drain();
      expect(session.state, AssistantState.paused);
      expect(tts.count('speak'), 0);
      expect(cancels, greaterThanOrEqualTo(2));
    },
  );
  test(
    'book/account switch pauses and cannot resume into the new context',
    () async {
      await session.start();
      final id = speech.id('startAssistantListening');
      scope = 'book2-account2';
      session.onContextChanged();
      speech.event(id, 'transcript', text: 'Stale');
      await drain();
      await session.resume();
      expect(questions, isEmpty);
      expect(session.state, AssistantState.paused);
      expect(speech.count('startAssistantListening'), 1);
    },
  );
  test(
    'background during speech stops TTS and never restarts the microphone',
    () async {
      await session.start();
      speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Question');
      await drain();
      answer.complete('Answer');
      await drain();
      final id = tts.id('speak');
      session.onBackground();
      tts.event(id, 'completed');
      await drain();
      expect(session.state, AssistantState.paused);
      expect(tts.count('stop'), 1);
      expect(speech.count('startAssistantListening'), 1);
    },
  );
  test(
    'resume waits pending TTS stop acknowledgement before opening microphone',
    () async {
      await session.start();
      speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Question');
      await drain();
      answer.complete('Answer');
      await drain();
      final stopped = Completer<void>();
      tts.behavior = (method, args) async {
        if (method == 'stop') await stopped.future;
      };
      final pause = session.pause();
      final resume = session.resume();
      await drain();
      expect(speech.count('startAssistantListening'), 1);
      stopped.complete();
      await Future.wait([pause, resume]);
      expect(speech.count('startAssistantListening'), 2);
    },
  );
  test('permission/network/busy errors never automatically rearm', () async {
    for (final code in ['permission_denied', 'network', 'busy']) {
      await session.start();
      final starts = speech.count('startAssistantListening');
      speech.event(speech.id('startAssistantListening'), 'error', code: code);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(session.state, AssistantState.error);
      expect(speech.count('startAssistantListening'), starts);
    }
  });
  test('safe ChatGPT failure reaches the assistant instead of a generic error',
      () async {
    await session.start();
    speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Q');
    await drain();
    answer.completeError(
        const ChatGptError('Step limit reached. Saved changes are intact.'));
    await drain();
    expect(session.state, AssistantState.error);
    expect(session.error, 'Step limit reached. Saved changes are intact.');
    expect(tts.count('speak'), 0);
  });
  test('model timeout is distinguishable from other assistant failures',
      () async {
    await session.start();
    speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Q');
    await drain();
    answer.completeError(TimeoutException('private transport details'));
    await drain();
    expect(session.state, AssistantState.error);
    expect(session.error,
        'The AI response timed out. Check the chat and saved changes before asking again.');
    expect(tts.count('speak'), 0);
  });
  test('unexpected failures never expose raw transport details', () async {
    await session.start();
    speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Q');
    await drain();
    answer.completeError(StateError('private transport details'));
    await drain();
    expect(session.state, AssistantState.error);
    expect(session.error,
        'Could not finish the response. Tap Resume to try again.');
  });
  test(
    'TTS failure stops the cycle without another model or ASR turn',
    () async {
      await session.start();
      speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Q');
      await drain();
      answer.complete('A');
      await drain();
      tts.event(tts.id('speak'), 'error', code: 'tts_failed');
      await drain();
      expect(session.state, AssistantState.error);
      expect(speech.count('startAssistantListening'), 1);
      expect(questions.length, 1);
    },
  );
  test(
    'stop/dispose reject stale events and cannot send another question',
    () async {
      await session.start();
      final id = speech.id('startAssistantListening');
      await session.stop();
      speech.event(id, 'transcript', text: 'late');
      await drain();
      expect(session.state, AssistantState.inactive);
      expect(questions, isEmpty);
      await session.start();
      final next = speech.id('startAssistantListening');
      session.dispose();
      speech.event(next, 'transcript', text: 'disposed');
      await drain();
      expect(questions, isEmpty);
    },
  );
  test(
    'stale queued-speak acknowledgement cannot fail the next listening cycle',
    () async {
      final accepted = Completer<void>();
      tts.behavior = (method, args) async {
        if (method == 'speak') await accepted.future;
      };
      await session.start();
      speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Q');
      await drain();
      answer.complete('A');
      await drain();
      tts.event(tts.id('speak'), 'completed');
      await drain();
      accepted.completeError(StateError('late ack'));
      await drain();
      expect(session.state, AssistantState.listening);
      expect(speech.count('startAssistantListening'), 2);
    },
  );
  test(
    'only plain answer text goes to TTS and huge answers stop safely',
    () async {
      expect(
        assistantSpeechText(
          '## Ответ\n**слово** [ссылка](https://example.com)',
        ),
        'Ответ\nслово ссылка',
      );
      await session.start();
      speech.event(speech.id('startAssistantListening'), 'transcript', text: 'Q');
      await drain();
      answer.complete('a' * 32001);
      await drain();
      expect(session.state, AssistantState.error);
      expect(tts.count('speak'), 0);
    },
  );
}
