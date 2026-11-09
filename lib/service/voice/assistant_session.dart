import 'dart:async';
import 'package:flutter/foundation.dart';
import 'assistant_tts.dart';
import 'reader_voice.dart';

enum AssistantState {
  inactive,
  listening,
  transcribing,
  thinking,
  speaking,
  paused,
  error,
}

String assistantSpeechText(String reply) => reply
    .replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^\)]+\)'),
      (match) => match.group(1)!,
    )
    .replaceAll(RegExp(r'^\s{0,3}(?:#{1,6}|[-*])\s+', multiLine: true), '')
    .replaceAll(RegExp(r'```[^\n]*\n?'), '')
    .replaceAll(RegExp(r'[*`_]'), '')
    .trim();

/// ReadingPage owns this session. Closing/collapsing a chat sheet does not own
/// its ASR, model turn, TTS or subscriptions. Ordinary dictation stays manual.
class AssistantSession extends ChangeNotifier {
  AssistantSession({
    ReaderVoiceNative? speech,
    AssistantTtsNative? tts,
    required this.sendQuestion,
    required this.currentScope,
    this.cancelQuestion,
    @visibleForTesting this.echoTail = const Duration(milliseconds: 250),
  }) : speech = speech ?? AndroidReaderVoiceNative.instance,
       tts = tts ?? AndroidAssistantTtsNative.instance {
    _speechEvents = this.speech.events.listen(_onSpeech);
    _ttsEvents = this.tts.events.listen(_onTts);
  }
  final ReaderVoiceNative speech;
  final AssistantTtsNative tts;
  final Future<String> Function(String) sendQuestion;
  final String Function() currentScope;
  final FutureOr<void> Function()? cancelQuestion;
  final Duration echoTail;
  Future<void> _cancellationTail = Future.value();
  late final StreamSubscription<Map<String, dynamic>> _speechEvents, _ttsEvents;
  AssistantState state = AssistantState.inactive;
  String transcript = '', reply = '', status = '';
  String? error;
  String language = 'ru-RU';
  String? _scope, _speechId, _ttsId;
  int _generation = 0, _counter = 0;
  bool _running = false, _disposed = false;
  Timer? _retry;
  bool get active => state != AssistantState.inactive;
  bool get busy => _running;
  String _id(String kind) =>
      'assistant_${kind}_${DateTime.now().microsecondsSinceEpoch}_${++_counter}';
  bool _valid(int generation) =>
      !_disposed &&
      _running &&
      generation == _generation &&
      _scope == currentScope();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start({String language = 'ru-RU'}) async {
    final cancellations = _invalidate();
    final generation = _generation;
    this.language = const ['ru-RU', 'es-ES', 'en-US'].contains(language)
        ? language
        : 'ru-RU';
    _scope = currentScope();
    _running = true;
    error = null;
    transcript = '';
    reply = '';
    state = AssistantState.listening;
    status = 'Starting voice assistant…';
    _notify();
    await cancellations;
    if (_valid(generation)) await _listen(generation);
  }

  Future<void> pause() async {
    final cancellations = _invalidate();
    if (state != AssistantState.inactive) {
      state = AssistantState.paused;
      status = 'Assistant paused.';
      error = null;
      _notify();
    }
    await cancellations;
  }

  Future<void> resume() async {
    if (_disposed || state == AssistantState.inactive) return;
    if (_scope != currentScope()) {
      state = AssistantState.paused;
      status = 'The book or chat changed. Restart the assistant.';
      _notify();
      return;
    }
    final cancellations = _invalidate();
    final generation = _generation;
    _running = true;
    error = null;
    state = AssistantState.listening;
    status = 'Resuming listening…';
    _notify();
    await cancellations;
    if (_valid(generation)) await _listen(generation);
  }

  Future<void> stop() async {
    final cancellations = _invalidate();
    state = AssistantState.inactive;
    status = '';
    error = null;
    _scope = null;
    _notify();
    await cancellations;
  }

  void onContextChanged() {
    if (_scope != null && _scope != currentScope()) {
      unawaited(pause());
      status = 'The book or chat changed. Assistant paused.';
      _notify();
    }
  }

  void onBackground() {
    if (active) {
      unawaited(pause());
      status = 'App in background. Assistant paused.';
      _notify();
    }
  }

  Future<void> _invalidate() {
    _generation++;
    _running = false;
    _retry?.cancel();
    _retry = null;
    final speechId = _speechId, ttsId = _ttsId;
    _speechId = null;
    _ttsId = null;
    // Backend cancellation must not block pause or leave the microphone open.
    final cancel = cancelQuestion;
    if (cancel != null) {
      unawaited(Future<void>.sync(cancel).catchError((_) {}));
    }
    _cancellationTail = Future.wait<void>([
      _cancellationTail,
      if (speechId != null) _quiet(speech.invoke('cancel', {'id': speechId})),
      if (ttsId != null) _quiet(tts.invoke('stop', {'id': ttsId})),
    ]).then((_) {});
    return _cancellationTail;
  }

  Future<void> _quiet(Future<void> future) async {
    try {
      await future;
    } catch (_) {}
  }

  Future<void> _listen(int generation) async {
    if (!_valid(generation)) return;
    final id = _id('asr');
    _speechId = id;
    transcript = '';
    state = AssistantState.listening;
    status = 'Listening for your question…';
    _notify();
    try {
      await speech.invoke('startAssistantListening', {
        'id': id,
        'language': language,
      });
    } catch (_) {
      if (_valid(generation) && _speechId == id)
        _fail('Could not start the microphone. Try again.');
    }
  }

  void _onSpeech(Map<String, dynamic> event) {
    if (_disposed || event['id'] != _speechId || !_running) return;
    if (_scope != currentScope()) {
      onContextChanged();
      return;
    }
    switch (event['type']) {
      case 'permission':
        status = 'Allow microphone access in the system dialog.';
      case 'starting' || 'listening':
        state = AssistantState.listening;
        status = 'Listening for your question…';
      case 'processing':
        state = AssistantState.transcribing;
        status = 'Transcribing your question…';
      case 'partial':
        transcript = _text(event['text']);
      case 'transcript':
        final id = _speechId!;
        final generation = _generation;
        _speechId = null;
        final text = _text(event['text']);
        if (text.isEmpty) {
          _silence(generation);
          return;
        }
        transcript = text;
        state = AssistantState.transcribing;
        status = 'Preparing your question…';
        _notify();
        unawaited(_answer(generation, id, text));
        return;
      case 'error':
        _speechId = null;
        if (event['code'] == 'no_match' || event['code'] == 'no_speech')
          _silence(_generation);
        else
          _fail(
            const [
                  'continuous_unsupported',
                  'continuous_ended',
                  'audio_source_failed',
                ].contains(event['code'])
                ? 'This Android service does not support quiet continuous listening. Use the dictation button instead.'
                : _speechError(event['code']),
          );
        return;
      case 'cancelled':
        unawaited(pause());
        return;
      default:
        return;
    }
    _notify();
  }

  void _silence(int generation) {
    if (!_valid(generation)) return;
    // A live audio-source session waits silently in native code. A terminal
    // no-speech response means this provider ended it: never auto-restart it.
    _fail(
      'Continuous listening ended. Tap Resume '
      'or use the dictation button.',
    );
  }

  Future<void> _answer(int generation, String speechId, String question) async {
    String? speakingId;
    try {
      // Recognition final normally destroys the native recognizer already.
      // Explicit cancellation also fences providers that finalize unusually.
      await speech.invoke('cancel', {'id': speechId});
      if (!_valid(generation)) return;
      state = AssistantState.thinking;
      status = 'Thinking about your question…';
      _notify();
      final answer = await sendQuestion(
        question,
      ).timeout(const Duration(minutes: 2));
      if (!_valid(generation)) return;
      reply = answer;
      final spoken = assistantSpeechText(answer);
      if (spoken.isEmpty) {
        _fail('Empty response. Try asking again.');
        return;
      }
      if (spoken.length > 32000) {
        _fail('The response is too long to read aloud. Open it in the chat.');
        return;
      }
      final id = _id('tts');
      speakingId = id;
      _ttsId = id;
      state = AssistantState.speaking;
      status = 'Reading the response aloud…';
      _notify();
      await tts.invoke('speak', {
        'id': id,
        'text': spoken,
        'language': language,
      });
      // Only a real native completed event may rearm ASR; invoke success means
      // the request was accepted, not that audio playback finished.
    } catch (_) {
      if (_valid(generation) && (speakingId == null || _ttsId == speakingId))
        _fail(
          'Could not finish the response. Tap Resume to try again.',
        );
    }
  }

  void _onTts(Map<String, dynamic> event) {
    if (_disposed || !_running || event['id'] != _ttsId) return;
    if (_scope != currentScope()) {
      onContextChanged();
      return;
    }
    switch (event['type']) {
      case 'started':
        state = AssistantState.speaking;
        status = 'Reading the response aloud…';
        _notify();
      case 'completed':
        _ttsId = null;
        final generation = _generation;
        _retry?.cancel();
        _retry = Timer(echoTail, () {
          _retry = null;
          if (_valid(generation)) unawaited(_listen(generation));
        });
      case 'error':
        _fail(
          event['code'] == 'language_unavailable'
              ? 'This language is unavailable for Android speech. Check installed voice data.'
              : 'Speech playback was interrupted. Tap Resume when ready.',
        );
      case 'cancelled':
        unawaited(pause());
    }
  }

  void _fail(String message) {
    unawaited(_invalidate());
    state = AssistantState.error;
    error = message;
    status = message;
    _notify();
  }

  String _text(dynamic value) => value is String
      ? value.substring(0, value.length.clamp(0, 4000)).trim()
      : '';
  String _speechError(dynamic code) => switch (code) {
    'permission_denied' =>
      'The assistant needs microphone access. Allow it for Anx in Android settings and try again.',
    'recognizer_unavailable' => 'Android speech recognition is unavailable.',
    'language_unavailable' => 'This language is unavailable for Android speech recognition.',
    'network' =>
      'Speech recognition network error. Tap Resume to try again.',
    'busy' =>
      'The microphone or recognizer is busy. Finish the other recording and try again.',
    _ => 'Speech recognition was interrupted. Tap Resume to try again.',
  };
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_invalidate());
    unawaited(_speechEvents.cancel());
    unawaited(_ttsEvents.cancel());
    super.dispose();
  }
}
