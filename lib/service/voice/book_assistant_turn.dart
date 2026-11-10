import 'dart:async';
import 'package:flutter/foundation.dart';

/// Preparation may canonicalize history, but cannot transfer a question to a
/// different book/account/provider while asynchronous history loading completes.
Future<void> prepareBookAssistantIdentity({
  required String Function() identity,
  required Future<void> Function() prepare,
  Future<void> Function()? initialize,
  String Function()? initializationIdentity,
}) async {
  if (initialize != null) {
    final guard = initializationIdentity ?? identity;
    final beforeInitialization = guard();
    await initialize();
    if (guard() != beforeInitialization) {
      throw StateError('The book or account changed. Ask again.');
    }
  }
  final expected = identity();
  await prepare();
  if (identity() != expected)
    throw StateError('The book or account changed. Ask again.');
}

/// Reader-owned request. The floating card may disappear without losing history.
class BookAssistantTurn extends ChangeNotifier {
  BookAssistantTurn({
    required this.prepare,
    required this.context,
    required this.scope,
    required this.stream,
    required this.cancelBackend,
  });
  final Future<void> Function() prepare;
  final Future<String?> Function() context;
  final String Function() scope;
  final Stream<String> Function(String, String?) stream;
  final void Function() cancelBackend;
  StreamSubscription<String>? _subscription;
  Completer<String>? _pending;
  int _generation = 0;
  bool _disposed = false;
  bool busy = false;
  String question = '', reply = '';
  String? error;
  String? _scope;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<String> send(String text) async {
    if (busy) throw StateError('Wait for the previous response.');
    final generation = ++_generation;
    _scope = null;
    busy = true;
    question = text;
    reply = '';
    error = null;
    _notify();
    final pending = Completer<String>();
    _pending = pending;
    // Attach an error handler before asynchronous preparation can be cancelled.
    final result = pending.future;
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    try {
      await prepare();
      if (generation != _generation) return await result;
      _scope = scope();
      final extra = await context();
      if (generation != _generation) return await result;
      if (_scope != scope()) throw StateError('The book or chat changed.');
      _subscription = stream(text, extra).listen(
        (answer) {
          if (generation != _generation) return;
          if (_scope != scope()) {
            cancel();
            return;
          }
          reply = answer;
          _notify();
        },
        onError: (Object e, StackTrace stack) {
          if (!pending.isCompleted) pending.completeError(e, stack);
        },
        onDone: () {
          if (pending.isCompleted) return;
          final value = reply.trim();
          if (value.isEmpty ||
              RegExp(
                r'^(Error:|Ошибка:|AI service not configured)',
                caseSensitive: false,
              ).hasMatch(value)) {
            pending.completeError(
              StateError(
                value.isEmpty ? 'Empty response. Check AI settings.' : value,
              ),
            );
          } else {
            pending.complete(value);
          }
        },
      );
      return await result;
    } catch (e) {
      if (generation == _generation) {
        error = '$e';
        _notify();
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        await _subscription?.cancel();
        _subscription = null;
        _pending = null;
        busy = false;
        _notify();
      }
    }
  }

  void contextChanged() {
    if (busy && _scope != null && _scope != scope()) cancel();
  }

  void cancel() {
    if (!busy) return;
    ++_generation;
    if (_subscription != null) cancelBackend();
    unawaited(_subscription?.cancel());
    _subscription = null;
    if (_pending?.isCompleted == false)
      _pending!.completeError(StateError('Request canceled.'));
    _pending = null;
    busy = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
