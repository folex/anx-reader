import 'package:anx_reader/service/voice/assistant_activity.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/voice/book_assistant_turn.dart';
import 'package:anx_reader/service/voice/reader_assistant_context.dart';

void main() {
  test('old request activity cannot overwrite the next turn', () async {
    final source = StreamController<String>.broadcast();
    final turn = BookAssistantTurn(
        prepare: () async {},
        context: () async => null,
        scope: () => 'one',
        stream: (_, __) => source.stream,
        cancelBackend: () {});
    final first = turn.send('first');
    final failure = expectLater(first, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final old = turn.activityListener;
    old(AssistantActivity.tools);
    expect(turn.activity, AssistantActivity.tools);
    await turn.cancel();
    await failure;
    final next = turn.send('next');
    final nextFailure = expectLater(next, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final current = turn.activity;
    old(AssistantActivity.disconnected);
    expect(turn.activity, current);
    await turn.cancel();
    await nextFailure;
    await source.close();
    turn.dispose();
  });
  test('first request accepts account restoration before capturing identity',
      () async {
    var account = 'not-loaded';
    var prepared = false;
    await prepareBookAssistantIdentity(
      initializationIdentity: () => 'book:provider:revision0',
      initialize: () async {
        account = 'restored';
      },
      identity: () => 'book:$account',
      prepare: () async {
        prepared = true;
      },
    );
    expect(account, 'restored');
    expect(prepared, true);
  });
  test(
      'book, provider or explicit account switch during initialization cancels',
      () async {
    for (final changed in [
      'otherbook:provider:revision0',
      'book:otherprovider:revision0',
      'book:provider:revision1'
    ]) {
      var guard = 'book:provider:revision0';
      var prepared = false;
      await expectLater(
          prepareBookAssistantIdentity(
            initializationIdentity: () => guard,
            initialize: () async {
              guard = changed;
            },
            identity: () => 'restored-account',
            prepare: () async {
              prepared = true;
            },
          ),
          throwsStateError);
      expect(prepared, false);
    }
  });
  test('prepare cannot transfer old utterance to new book/account', () async {
    var identity = 'book:account';
    final ready = Completer<void>();
    final result = prepareBookAssistantIdentity(
      identity: () => identity,
      prepare: () => ready.future,
    );
    final failed = expectLater(result, throwsStateError);
    identity = 'otherbook:account';
    ready.complete();
    await failed;
    await prepareBookAssistantIdentity(
      identity: () => identity,
      prepare: () async {},
    );
  });
  test(
    'cancel during context preparation never cancels another backend turn',
    () async {
      final context = Completer<String?>();
      var cancelled = 0, subscribed = false;
      final adapter = BookAssistantTurn(
        prepare: () async {},
        context: () => context.future,
        scope: () => 'book',
        cancelBackend: () {
          cancelled++;
        },
        stream: (_, __) {
          subscribed = true;
          return Stream.value('answer');
        },
      );
      final result = adapter.send('question');
      final failure = expectLater(result, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      adapter.cancel();
      context.complete('context');
      await failure;
      expect(cancelled, 0);
      expect(subscribed, false);
      adapter.dispose();
    },
  );

  test(
    'one turn survives listener/card removal; bounded fresh context for each request',
    () async {
      var contextCalls = 0, prepareCalls = 0;
      final source = StreamController<String>();
      final adapter = BookAssistantTurn(
        prepare: () async {
          prepareCalls++;
        },
        context: () async => 'viewport${++contextCalls}',
        scope: () => 'book1',
        cancelBackend: () {},
        stream: (q, c) {
          expect(q, 'hola');
          expect(c, 'viewport1');
          return source.stream;
        },
      );
      void listener() {}
      adapter.addListener(listener);
      final answer = adapter.send('hola');
      await Future<void>.delayed(Duration.zero);
      expect(adapter.busy, true);
      await expectLater(adapter.send('duplicate'), throwsStateError);
      adapter.removeListener(listener);
      source.add('Смысл');
      await source.close();
      expect(await answer, 'Смысл');
      expect(adapter.busy, false);
      expect(prepareCalls, 1);
      adapter.dispose();
    },
  );
  test(
    'cancel immediately fences late output and releases local lock',
    () async {
      var cancelled = 0;
      final source = StreamController<String>();
      final adapter = BookAssistantTurn(
        prepare: () async {},
        context: () async => null,
        scope: () => 'one',
        cancelBackend: () {
          cancelled++;
        },
        stream: (_, __) => source.stream,
      );
      final result = adapter.send('one');
      final failure = expectLater(result, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      adapter.cancel();
      source.add('late');
      await failure;
      expect(adapter.reply, '');
      expect(adapter.busy, false);
      expect(cancelled, 1);
      await source.close();
      adapter.dispose();
    },
  );
  test(
    'model errors never become spoken answers or successful turns',
    () async {
      final adapter = BookAssistantTurn(
        prepare: () async {},
        context: () async => null,
        scope: () => 'one',
        cancelBackend: () {},
        stream: (_, __) => Stream.value('Error: unauthorized'),
      );
      await expectLater(adapter.send('hello'), throwsStateError);
      expect(adapter.busy, false);
      expect(adapter.error, contains('unauthorized'));
      adapter.dispose();
    },
  );
  test(
    'external history/account scope change cancels but page-only change does not',
    () async {
      var scope = 'book:account:history';
      final source = StreamController<String>();
      var cancels = 0;
      final adapter = BookAssistantTurn(
        prepare: () async {},
        context: () async => null,
        scope: () => scope,
        cancelBackend: () {
          cancels++;
        },
        stream: (_, __) => source.stream,
      );
      final result = adapter.send('q');
      final failure = expectLater(result, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      adapter.contextChanged();
      expect(cancels, 0);
      scope = 'book:otheraccount:history';
      adapter.contextChanged();
      await failure;
      expect(cancels, 1);
      await source.close();
      adapter.dispose();
    },
  );
  test(
    'context is bounded, metadata-only when viewport absent, original selection preferred',
    () {
      final value = buildReaderTutorContext(
        title: 'Title',
        chapter: 'One',
        viewport: {'visible': 'x' * 9000, 'selection': 'hola'},
        selectionFallback: 'stale',
      );
      expect(value, contains('hola'));
      expect(value, isNot(contains('stale')));
      expect(value.length, lessThan(2500));
      expect(
        buildReaderTutorContext(title: 'Title', chapter: 'One', viewport: null),
        contains('Title'),
      );
    },
  );
}
