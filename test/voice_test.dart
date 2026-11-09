import 'dart:async';
import 'package:anx_reader/service/voice/reader_voice.dart';
import 'package:anx_reader/widgets/ai/reader_voice_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeNative implements ReaderVoiceNative {
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

  String get lastStartId =>
      calls.lastWhere(
            (call) =>
                call['method'] == 'startDictation' ||
                call['method'] == 'startAssistant',
          )['id']
          as String;
  void event(
    String type, {
    String? id,
    String? text,
    String? code,
    String? choice,
  }) => controller.add({
    'id': id ?? lastStartId,
    'type': type,
    if (text != null) 'text': text,
    if (code != null) 'code': code,
    if (choice != null) 'choice': choice,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeNative native;
  late ReaderVoiceController voice;
  late List<String> drafts;
  late String scope;
  setUp(() {
    native = FakeNative();
    drafts = [];
    scope = 'book1-accountA-panel1';
    voice = ReaderVoiceController(
      native: native,
      currentScope: () => scope,
      onDraft: drafts.add,
    );
  });
  tearDown(() async {
    voice.dispose();
    await native.controller.close();
  });
  test(
    'partials are preview only; final text delivered once without auto-send',
    () async {
      await voice.startDictation();
      native.event('listening');
      native.event('partial', text: 'Что зна');
      expect(voice.preview, 'Что зна');
      expect(drafts, isEmpty);
      native.event('transcript', text: 'Что значит acostumbrarse?');
      native.event('transcript', text: 'duplicate');
      expect(drafts, ['Что значит acostumbrarse?']);
      expect(voice.busy, false);
      expect(voice.preview, isEmpty);
    },
  );
  test(
    'speech default is Russian and language changes are blocked while recording',
    () async {
      await voice.startDictation();
      expect(native.calls.last['language'], 'ru-RU');
      voice.setLanguage('es-ES');
      expect(voice.language, 'ru-RU');
      await voice.cancel();
      voice.setLanguage('es-ES');
      await voice.startDictation();
      expect(native.calls.last['language'], 'es-ES');
    },
  );
  test('stop waits for final result and cannot be repeated', () async {
    await voice.startDictation();
    await voice.stopDictation();
    expect(native.calls.where((c) => c['method'] == 'stopDictation'), isEmpty);
    native.event('listening');
    await voice.stopDictation();
    await voice.stopDictation();
    expect(native.calls.where((c) => c['method'] == 'stopDictation').length, 1);
    expect(drafts, isEmpty);
    native.event('transcript', text: 'Done');
    expect(drafts, ['Done']);
  });
  test(
    'permission denial leaves draft untouched and retry owns fresh callbacks',
    () async {
      await voice.startDictation();
      final oldId = native.lastStartId;
      native.event('permission');
      expect(voice.phase, 'permission');
      expect(voice.canStop, false);
      native.event('error', code: 'permission_denied');
      expect(drafts, isEmpty);
      expect(voice.busy, false);
      await voice.startDictation();
      expect(native.lastStartId, isNot(oldId));
      native.event('transcript', id: oldId, text: 'stale denied request');
      expect(drafts, isEmpty);
      native.event('transcript', text: 'Retry worked');
      expect(drafts, ['Retry worked']);
    },
  );
  test(
    'book/account change rejects late voice result and cancels native owner',
    () async {
      await voice.startDictation();
      final id = native.lastStartId;
      scope = 'book2-accountB-panel1';
      native.event('transcript', text: 'Wrong book');
      await Future<void>.delayed(Duration.zero);
      expect(drafts, isEmpty);
      expect(native.calls.last, {'method': 'cancel', 'id': id});
    },
  );
  test('explicit cancel rejects a late final and partial', () async {
    await voice.startDictation();
    final id = native.lastStartId;
    await voice.cancel();
    native.event('partial', id: id, text: 'late');
    native.event('transcript', id: id, text: 'late');
    expect(drafts, isEmpty);
    expect(voice.preview, isEmpty);
  });
  test(
    'local assistant returns only a finished standard option as an editable question',
    () async {
      await voice.startAssistant({
        'selection': 'se había acostumbrado',
        'title': 'Book',
        'chapter': 'One',
        'question': 'My question',
      });
      native.event('assistantStarting');
      native.event('assistantLocal');
      native.event('assistantChoosing');
      expect(drafts, isEmpty);
      native.event('assistantChoice', choice: 'grammar');
      expect(
        drafts.single,
        'Объясни грамматику в этом фрагменте: «se había acostumbrado»',
      );
      expect(voice.busy, false);
    },
  );
  test(
    'one-way assistant fallback remains honest and its context clears on panel/book switch',
    () async {
      await voice.startAssistant({'selection': 'excerpt'});
      final id = native.lastStartId;
      native.event('assistantExternal');
      expect(drafts, isEmpty);
      expect(voice.status, contains('will not return'));
      expect(voice.busy, false);
      scope = 'book2';
      voice.contextChanged();
      await Future<void>.delayed(Duration.zero);
      expect(native.calls.last, {'method': 'cancel', 'id': id});
      expect(drafts, isEmpty);
    },
  );
  test('assistant input is bounded before native handoff', () async {
    await voice.startAssistant({
      'selection': 's' * 5000,
      'question': 'q' * 4000,
      'title': 't' * 500,
      'chapter': 'c' * 500,
    });
    expect((native.calls.last['selection'] as String).length, 2000);
    expect((native.calls.last['question'] as String).length, 1000);
    expect((native.calls.last['title'] as String).length, 200);
  });
  test(
    'native launch failure exits busy state and best-effort cancels session',
    () async {
      native.behavior = (method, args) async {
        if (method == 'startDictation')
          throw StateError('private native details');
      };
      await voice.startDictation();
      expect(voice.busy, false);
      expect(voice.status, isNot(contains('private native details')));
      expect(native.calls.last['method'], 'cancel');
      expect(drafts, isEmpty);
    },
  );
  test(
    'scope change while old cancellation is pending cannot start recording',
    () async {
      await voice.startDictation();
      final pending = Completer<void>();
      native.behavior = (method, args) async {
        if (method == 'cancel') await pending.future;
      };
      final start = voice.startDictation();
      scope = 'different book';
      pending.complete();
      await start;
      expect(
        native.calls.where((c) => c['method'] == 'startDictation').length,
        1,
      );
      expect(voice.busy, false);
    },
  );
  test(
    'disposed panel ignores late results and cancels its native owner',
    () async {
      final localDrafts = <String>[];
      final local = ReaderVoiceController(
        native: native,
        currentScope: () => scope,
        onDraft: localDrafts.add,
      );
      await local.startDictation();
      final id = native.lastStartId;
      local.dispose();
      await Future<void>.delayed(Duration.zero);
      native.event('transcript', id: id, text: 'late closed-panel answer');
      expect(localDrafts, isEmpty);
      expect(native.calls.last, {'method': 'cancel', 'id': id});
    },
  );
  test(
    'editing helper preserves current typed prefix/suffix and never erases selection',
    () {
      expect(
        insertVoiceDraft('Hola mundo', 5, 'pregunta'),
        'Hola pregunta mundo',
      );
      expect(insertVoiceDraft('typed', 999, 'question'), 'typed question');
      expect(insertVoiceDraft('typed', 0, ''), 'typed');
    },
  );
  testWidgets(
    'both experimental buttons fit a narrow 360px chat without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderVoiceToolbar(
              controller: voice,
              assistantContext: () => {'selection': 'texto'},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      expect(find.byIcon(Icons.assistant_outlined), findsOneWidget);
      expect(find.text('RU'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
