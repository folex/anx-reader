import 'dart:async';
import 'package:flutter/services.dart';

abstract interface class AssistantTtsNative {
  Stream<Map<String, dynamic>> get events;
  Future<void> invoke(String method, Map<String, dynamic> arguments);
}

/// An independent native TextToSpeech instance; never replaces book TTS handlers.
class AndroidAssistantTtsNative implements AssistantTtsNative {
  static final instance = AndroidAssistantTtsNative._();
  AndroidAssistantTtsNative._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'ttsEvent' && call.arguments is Map) {
        _events.add(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }
  static const _channel = MethodChannel('com.anxcye.anx_reader/assistant_tts');
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<void> invoke(String method, Map<String, dynamic> arguments) =>
      _channel.invokeMethod<void>(method, arguments);
}
