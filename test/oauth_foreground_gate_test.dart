import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/oauth_foreground_gate.dart';
import 'package:anx_reader/service/chatgpt/protocol.dart';

class TrackedForeground extends ValueNotifier<bool> {
  TrackedForeground(super.value);
  bool get subscribed => hasListeners;
}

void main() {
  test(
    'background callback never sends token POST; resume starts exactly once',
    () async {
      final state = ValueNotifier(false);
      final gate = OAuthForegroundGate(
        isCurrent: () => true,
        foreground: state,
      );
      var posts = 0;
      final result = gate.run(() async {
        posts++;
        return 'token';
      });
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
      state.value = true;
      expect(await result, 'token');
      state.value = false;
      state.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(posts, 1);
      gate.dispose();
      state.dispose();
    },
  );
  test(
    'cancel after callback wakes immediately and later resume cannot POST',
    () async {
      final state = ValueNotifier(false);
      final gate = OAuthForegroundGate(
        isCurrent: () => true,
        foreground: state,
      );
      var posts = 0;
      final request = gate.run(() async {
        posts++;
      });
      final failure = expectLater(request, throwsA(isA<ChatGptError>()));
      gate.cancel();
      await failure.timeout(const Duration(seconds: 1));
      state.value = true;
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
      gate.dispose();
      state.dispose();
    },
  );
  test('timeout and epoch change prevent later POST', () async {
    final state = ValueNotifier(false);
    var current = true;
    var posts = 0;
    final timed = OAuthForegroundGate(
      isCurrent: () => true,
      foreground: state,
      limit: const Duration(milliseconds: 10),
    );
    await expectLater(
      timed.run(() async {
        posts++;
      }),
      throwsA(isA<ChatGptError>()),
    );
    state.value = true;
    await Future<void>.delayed(Duration.zero);
    expect(posts, 0);
    timed.dispose();
    state.value = false;
    final stale = OAuthForegroundGate(
      isCurrent: () => current,
      foreground: state,
    );
    final result = stale.run(() async {
      posts++;
    });
    final failed = expectLater(result, throwsA(isA<ChatGptError>()));
    current = false;
    state.value = true;
    await failed;
    expect(posts, 0);
    stale.dispose();
    state.dispose();
  });
  test(
    'second JWKS phase waits if backgrounded after one successful token exchange',
    () async {
      final state = ValueNotifier(true);
      final gate = OAuthForegroundGate(
        isCurrent: () => true,
        foreground: state,
      );
      var posts = 0, gets = 0;
      await gate.run(() async {
        posts++;
        state.value = false;
      });
      final verify = gate.run(() async {
        gets++;
      });
      await Future<void>.delayed(Duration.zero);
      expect(posts, 1);
      expect(gets, 0);
      state.value = true;
      await verify;
      expect(posts, 1);
      expect(gets, 1);
      gate.dispose();
      state.dispose();
    },
  );
  test(
    'dispose removes lifecycle listener and one overall budget never resets',
    () async {
      final state = TrackedForeground(false);
      final gate = OAuthForegroundGate(
        isCurrent: () => true,
        foreground: state,
        limit: const Duration(milliseconds: 50),
      );
      expect(state.subscribed, true);
      final initial = gate.remaining;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(gate.remaining, lessThan(initial));
      final wait = gate.waitUntilForeground();
      final failed = expectLater(wait, throwsA(isA<ChatGptError>()));
      gate.dispose();
      await failed;
      expect(state.subscribed, false);
      state.dispose();
    },
  );
  test(
    'cancel during active network phase resolves promptly and ignores late result',
    () async {
      final state = ValueNotifier(true);
      final gate = OAuthForegroundGate(
        isCurrent: () => true,
        foreground: state,
      );
      final pending = Completer<String>();
      var gets = 0;
      final action = gate.run(() => pending.future);
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(action, throwsA(isA<ChatGptError>()));
      gate.cancel();
      await failed.timeout(const Duration(seconds: 1));
      pending.complete('late token');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        gate.run(() async {
          gets++;
        }),
        throwsA(isA<ChatGptError>()),
      );
      expect(gets, 0);
      gate.dispose();
      state.dispose();
    },
  );
  test(
    'pause between foreground wait and action continuation waits for next resume',
    () async {
      final state = ValueNotifier(true);
      final gate = OAuthForegroundGate(
        isCurrent: () => true,
        foreground: state,
      );
      var posts = 0;
      final request = gate.run(() async {
        posts++;
      });
      state.value = false;
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
      state.value = true;
      state.value = false;
      await Future<void>.delayed(Duration.zero);
      expect(posts, 0);
      state.value = true;
      await request;
      expect(posts, 1);
      gate.dispose();
      state.dispose();
    },
  );
}
