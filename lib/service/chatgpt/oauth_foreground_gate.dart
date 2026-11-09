import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'protocol.dart';

/// One OAuth attempt owns one foreground subscription and one total deadline.
/// Authorization codes and tokens never leave the caller's transient memory.
class OAuthForegroundGate {
  OAuthForegroundGate({
    required this.isCurrent,
    Duration limit = const Duration(minutes: 5),
    @visibleForTesting ValueListenable<bool>? foreground,
  }) {
    _watch.start();
    _limit = limit;
    if (foreground != null) {
      _foreground = foreground.value;
      void changed() {
        _foreground = foreground.value;
        _wake();
      }

      foreground.addListener(changed);
      _remove = () => foreground.removeListener(changed);
    } else {
      _foreground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      final listener = AppLifecycleListener(
        onStateChange: (state) {
          _foreground = state == AppLifecycleState.resumed;
          _wake();
        },
      );
      _remove = listener.dispose;
    }
    _deadline = Timer(limit, () {
      _finish(
        const ChatGptError(
          'Sign-in timed out. Tap Continue with ChatGPT again.',
        ),
      );
    });
  }
  final bool Function() isCurrent;
  final Stopwatch _watch = Stopwatch();
  late final Duration _limit;
  late final Timer _deadline;
  late final VoidCallback _remove;
  bool _foreground = false, _disposed = false;
  ChatGptError? _failure;
  Completer<void>? _waiting;
  final Completer<void> _terminated = Completer<void>();
  Duration get remaining {
    final value = _limit - _watch.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  void _check() {
    if (_failure != null) throw _failure!;
    if (_disposed || !isCurrent())
      throw const ChatGptError('Sign-in canceled; connect again.');
    if (remaining == Duration.zero)
      throw const ChatGptError(
        'Sign-in timed out. Tap Continue with ChatGPT again.',
      );
  }

  void _wake() {
    final waiter = _waiting;
    _waiting = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> waitUntilForeground() async {
    while (true) {
      _check();
      if (_foreground) return;
      final waiter = _waiting ??= Completer<void>();
      await waiter.future;
    }
  }

  Future<T> run<T>(Future<T> Function() action) async {
    do {
      await waitUntilForeground();
      _check();
    } while (!_foreground);
    // No await between this final check and starting the network phase.
    final result = await Future.any<T>([
      action(),
      _terminated.future.then<T>((_) {
        _check();
        throw const ChatGptError('Sign-in canceled.');
      }),
    ]);
    _check();
    return result;
  }

  void _finish(ChatGptError failure) {
    _failure ??= failure;
    _wake();
    if (!_terminated.isCompleted) _terminated.complete();
  }

  void cancel() => _finish(const ChatGptError('Sign-in canceled.'));
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _deadline.cancel();
    _remove();
    _watch.stop();
    _finish(const ChatGptError('Sign-in canceled.'));
  }
}
