import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class ReaderVoiceNative {
  Stream<Map<String, dynamic>> get events;
  Future<void> invoke(String method, Map<String, dynamic> arguments);
}

class AndroidReaderVoiceNative implements ReaderVoiceNative {
  static final instance = AndroidReaderVoiceNative._();
  AndroidReaderVoiceNative._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'voiceEvent' && call.arguments is Map) {
        _events.add(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }
  static const _channel = MethodChannel('com.anxcye.anx_reader/voice');
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<void> invoke(String method, Map<String, dynamic> arguments) =>
      _channel.invokeMethod<void>(method, arguments);
}

String insertVoiceDraft(String draft, int offset, String incoming) {
  final text = incoming.trim();
  if (text.isEmpty) return draft;
  final caret = offset.clamp(0, draft.length);
  final before = draft.substring(0, caret), after = draft.substring(caret);
  return before +
      (before.isNotEmpty && !RegExp(r'\s$').hasMatch(before) ? ' ' : '') +
      text +
      (after.isNotEmpty && !RegExp(r'^\s').hasMatch(after) ? ' ' : '') +
      after;
}

class ReaderVoiceController extends ChangeNotifier {
  ReaderVoiceController({
    required this.currentScope,
    required this.onDraft,
    ReaderVoiceNative? native,
  }) : native = native ?? AndroidReaderVoiceNative.instance {
    _subscription = this.native.events.listen(_event);
  }
  final String Function() currentScope;
  final void Function(String) onDraft;
  final ReaderVoiceNative native;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  String language = 'ru-RU';
  String phase = 'idle';
  String? kind;
  String preview = '';
  String status = '';
  String? _activeId, _nativeId, _scope;
  Map<String, String> _context = {};
  int _counter = 0;
  bool _disposed = false;
  bool get busy => _activeId != null;
  bool get canStop => kind == 'dictation' && phase == 'listening';

  void setLanguage(String value) {
    if (!busy && const ['ru-RU', 'es-ES', 'en-US'].contains(value)) {
      language = value;
      notifyListeners();
    }
  }

  Future<void> startDictation() => _start('dictation', {});
  Future<void> startAssistant(Map<String, String> context) =>
      _start('assistant', context);
  Future<void> _start(String nextKind, Map<String, String> context) async {
    final scope = currentScope();
    await cancel(clearStatus: false);
    if (_disposed || currentScope() != scope) return;
    final id = '${DateTime.now().microsecondsSinceEpoch}_${++_counter}';
    _activeId = id;
    _nativeId = id;
    _scope = scope;
    context = context.map(
      (key, value) => MapEntry(
        key,
        value.substring(
          0,
          value.length.clamp(
            0,
            key == 'selection'
                ? 2000
                : key == 'question'
                ? 1000
                : 200,
          ),
        ),
      ),
    );
    _context = Map.from(context);
    kind = nextKind;
    phase = 'starting';
    preview = '';
    status = nextKind == 'dictation'
        ? 'Starting Android speech recognition…'
        : 'Starting Android assistant…';
    notifyListeners();
    try {
      await native.invoke(
        nextKind == 'dictation' ? 'startDictation' : 'startAssistant',
        {
          'id': id,
          if (nextKind == 'dictation') 'language': language,
          if (nextKind == 'assistant') ...context,
        },
      );
    } catch (_) {
      if (_activeId == id) {
        _finish(
          'Could not start Android voice services. Try again.',
        );
        try {
          await native.invoke('cancel', {'id': id});
        } catch (_) {}
      }
    }
  }

  Future<void> stopDictation() async {
    if (!canStop || _activeId == null) return;
    final id = _activeId!;
    phase = 'processing';
    status = 'Finishing transcription…';
    notifyListeners();
    try {
      await native.invoke('stopDictation', {'id': id});
    } catch (_) {
      if (_activeId == id) {
        _finish('Could not finish transcription. Try recording again.');
        try {
          await native.invoke('cancel', {'id': id});
        } catch (_) {}
      }
    }
  }

  Future<void> cancel({bool clearStatus = true}) async {
    final id = _nativeId;
    _activeId = null;
    _nativeId = null;
    _scope = null;
    kind = null;
    phase = 'idle';
    preview = '';
    _context = {};
    if (clearStatus) status = '';
    if (!_disposed) notifyListeners();
    if (id != null) {
      try {
        await native.invoke('cancel', {'id': id});
      } catch (_) {}
    }
  }

  void contextChanged() {
    if (_scope != null && _scope != currentScope()) unawaited(cancel());
  }

  void _event(Map<String, dynamic> event) {
    if (_disposed || event['id'] != _activeId) return;
    if (_scope != currentScope()) {
      unawaited(cancel());
      return;
    }
    final type = event['type'];
    switch (type) {
      case 'permission':
        phase = 'permission';
        status = 'Allow microphone access in the system dialog.';
      case 'starting':
        phase = 'starting';
        status = 'Connecting microphone…';
      case 'listening':
        phase = 'listening';
        status = 'Listening. Tap Stop to finish recording.';
      case 'processing':
        phase = 'processing';
        status = 'Transcribing speech…';
      case 'partial':
        preview = _text(event['text']);
      case 'transcript':
        final text = _text(event['text']);
        _finish(
          text.isEmpty
              ? 'No speech recognized. Try again.'
              : 'Text added to your draft. Review and send it.',
        );
        if (text.isNotEmpty) onDraft(text);
        return;
      case 'assistantStarting':
        phase = 'assistantStarting';
        status = 'Checking local voice session…';
      case 'assistantLocal':
        phase = 'assistantLocal';
        status =
            'Choose meaning, grammar, or phrases.';
      case 'assistantChoosing':
        phase = 'assistantLocal';
        status = 'Assistant is checking your choice…';
      case 'assistantChoice':
        final choice = event['choice'];
        final prompt = switch (choice) {
          'meaning' => 'Объясни значение и перевод',
          'grammar' => 'Объясни грамматику',
          'idioms' => 'Разбери слова и устойчивые выражения',
          _ => null,
        };
        final selection = (_context['selection'] ?? '').trim();
        _finish(
          prompt == null
              ? 'Could not determine your choice.'
              : 'Question added to your draft. Review and send it.',
        );
        if (prompt != null)
          onDraft(
            selection.isNotEmpty
                ? '$prompt в этом фрагменте: «$selection»'
                : '$prompt в текущем фрагменте книги.',
          );
        return;
      case 'assistantExternal':
        // Keep the native owner ID only so closing/changing this panel clears
        // the temporary assist context even after this one-way handoff.
        _activeId = null;
        kind = null;
        phase = 'idle';
        preview = '';
        status =
            'System assistant opened with book context. Its response will not return to the Anx chat.';
      case 'cancelled':
        _finish('Voice input canceled.');
        return;
      case 'error':
        _finish(_error(event['code']));
        return;
      default:
        return;
    }
    notifyListeners();
  }

  String _text(dynamic value) => value is String
      ? value.substring(0, value.length.clamp(0, 4000)).trim()
      : '';
  void _finish(String message) {
    _activeId = null;
    _nativeId = null;
    _scope = null;
    kind = null;
    phase = 'idle';
    preview = '';
    _context = {};
    status = message;
    if (!_disposed) notifyListeners();
  }

  String _error(dynamic code) => switch (code) {
    'permission_denied' =>
      'Microphone access denied. Allow it for Anx in Android settings and try again.',
    'permission_pending' =>
      'Close the existing permission dialog and try again.',
    'recognizer_unavailable' =>
      'No Android speech recognition service found.',
    'assistant_unavailable' =>
      'Android assistant is unavailable. Check your default digital assistant.',
    'no_match' || 'no_speech' => 'No speech recognized. Try again.',
    'network' => 'Speech recognition network error. Try again.',
    'language_unavailable' =>
      'This language is unavailable for speech recognition. Try another language.',
    'busy' => 'Speech recognizer is busy. Try again in a few seconds.',
    'timeout' => 'Voice input timed out. Try again.',
    _ => 'Voice service did not complete the request. Try again.',
  };
  @override
  void dispose() {
    _disposed = true;
    unawaited(cancel());
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
