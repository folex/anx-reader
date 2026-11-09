import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/voice/assistant_session.dart';
import 'package:anx_reader/service/voice/assistant_tts.dart';
import 'package:anx_reader/service/voice/reader_voice.dart';

class Native implements ReaderVoiceNative, AssistantTtsNative {
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  final calls = <Map<String, dynamic>>[];
  Stream<Map<String, dynamic>> get events => controller.stream;
  Future<void> invoke(String method, Map<String, dynamic> args) async {
    calls.add({'method': method, ...args});
  }

  String get id =>
      calls.lastWhere((x) => x['method'] == 'startAssistantListening')['id']
          as String;
  void event(String type, {String? code, String? text}) =>
      controller.add({'id': id, 'type': type, 'code': code, 'text': text});
  int count(String m) => calls.where((x) => x['method'] == m).length;
}

Future<void> drain() async {
  for (var i = 0; i < 8; i++) await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Native speech, tts;
  late AssistantSession session;
  late String scope;
  late List<String> questions;
  setUp(() {
    speech = Native();
    tts = Native();
    scope = 'book1';
    questions = [];
    session = AssistantSession(
      speech: speech,
      tts: tts,
      currentScope: () => scope,
      echoTail: Duration.zero,
      sendQuestion: (q) async {
        questions.add(q);
        return 'Короткий ответ.';
      },
    );
  });
  tearDown(() {
    session.dispose();
  });
  testWidgets(
    'idle silence keeps one continuous source and never dictation/restart',
    (tester) async {
      await tester.runAsync(() => session.start());
      await tester.pump(const Duration(minutes: 3));
      expect(speech.count('startAssistantListening'), 1);
      expect(speech.count('startDictation'), 0);
      expect(session.state, AssistantState.listening);
      expect(questions, isEmpty);
    },
  );
  for (final code in [
    'no_speech',
    'no_match',
    'continuous_ended',
    'continuous_unsupported',
  ]) {
    testWidgets('terminal $code never restarts', (tester) async {
      await tester.runAsync(() => session.start());
      speech.event('error', code: code);
      await tester.pump(const Duration(minutes: 3));
      expect(speech.count('startAssistantListening'), 1);
      expect(session.state, AssistantState.error);
      expect(questions, isEmpty);
    });
  }
  test(
    'final cancels mic before AI and real TTS completion rearms once',
    () async {
      await session.start();
      speech.event('transcript', text: 'Что значит ira?');
      await drain();
      expect(questions, ['Что значит ira?']);
      expect(speech.count('cancel'), 1);
      expect(tts.count('speak'), 1);
      expect(speech.count('startAssistantListening'), 1);
      final id = tts.calls.last['id'];
      tts.controller.add({'id': id, 'type': 'completed'});
      await drain();
      expect(speech.count('startAssistantListening'), 2);
    },
  );
  test('background closes mic and late transcript cannot send', () async {
    await session.start();
    session.onBackground();
    speech.event('transcript', text: 'late');
    await drain();
    expect(speech.count('cancel'), 1);
    expect(questions, isEmpty);
    expect(session.state, AssistantState.paused);
  });
  test('book switch fences late ASR', () async {
    await session.start();
    scope = 'book2';
    speech.event('transcript', text: 'late');
    await drain();
    expect(questions, isEmpty);
    expect(speech.count('cancel'), 1);
    expect(session.state, AssistantState.paused);
  });
}
