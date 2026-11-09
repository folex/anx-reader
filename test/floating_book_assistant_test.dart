import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/voice/assistant_session.dart';
import 'package:anx_reader/service/voice/reader_voice.dart';
import 'package:anx_reader/service/voice/assistant_tts.dart';
import 'package:anx_reader/service/voice/book_assistant_turn.dart';
import 'package:anx_reader/widgets/ai/floating_book_assistant.dart';

class Speech implements ReaderVoiceNative {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> invoke(String method, Map<String, dynamic> args) async {}
}

class Tts implements AssistantTtsNative {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> invoke(String method, Map<String, dynamic> args) async {}
}

void main() {
  testWidgets(
    'compact panel remains usable at 320px and large text; collapse exposes reader',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var bookTaps = 0;
      var hintsOpened = 0;
      var illustrationsOpened = 0;
      final turn = BookAssistantTurn(
        prepare: () async {},
        context: () async => null,
        scope: () => 'book',
        cancelBackend: () {},
        stream: (_, __) => Stream.value('Respuesta'),
      );
      final session = AssistantSession(
        speech: Speech(),
        tts: Tts(),
        sendQuestion: turn.send,
        currentScope: () => 'book',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 700),
              textScaler: TextScaler.linear(1.5),
            ),
            child: Scaffold(
              body: Stack(
                children: [
                  Center(
                      child: TextButton(
                          onPressed: () => bookTaps++,
                          child: const Text('BOOK'))),
                  Positioned.fill(
                    child: FloatingBookAssistant(
                      session: session,
                      turn: turn,
                      scope: () => 'book',
                      startVoice: (_) async {},
                      close: () {},
                      history: () {},
                      hints: () => hintsOpened++,
                      illustrations: () => illustrationsOpened++,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Collapse conversation'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('BOOK'), findsOneWidget);
      expect(
        tester.getSize(find.byType(Column).first).height,
        lessThanOrEqualTo(64),
      );
      await session.start();
      await tester.pump();
      await tester.tap(find.byTooltip('Minimize assistant'));
      await tester.pump();
      final bubble = find.byKey(const ValueKey('assistant-bubble'));
      expect(bubble, findsOneWidget);
      expect(session.state, AssistantState.listening);
      expect(tester.getSize(bubble), const Size(52, 52));
      await tester.tap(find.text('BOOK'));
      await tester.pump();
      expect(bookTaps, 1);
      final before = tester.getTopLeft(bubble);
      await tester.drag(find.byKey(const ValueKey('assistant-bubble-drag')),
          const Offset(-400, 500));
      await tester.pump();
      final after = tester.getTopLeft(bubble);
      expect(after.dx, lessThan(before.dx));
      expect(after.dy, greaterThan(before.dy));
      expect(after.dx, greaterThanOrEqualTo(12));
      expect(after.dy + 52, lessThanOrEqualTo(700 - 12));
      expect(session.state, AssistantState.listening);
      await tester.tap(bubble);
      await tester.pump();
      expect(bubble, findsNothing);
      expect(find.byTooltip('Show conversation'), findsOneWidget);
      expect(session.state, AssistantState.listening);
      await tester.tap(find.byTooltip('Assistant menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reading hints'));
      await tester.pumpAndSettle();
      expect(hintsOpened, 1);
      await tester.tap(find.byTooltip('Assistant menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Illustrations'));
      await tester.pumpAndSettle();
      expect(illustrationsOpened, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      turn.dispose();
    },
  );
}
