import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

// Dart's WebSocket upgrade copies Uri.port before changing wss to https;
// an implicit wss port becomes 0 in the pinned SDK. Preserve HTTPS port 443.
const chatGptResponsesWebSocketUrl = 'wss://api.openai.com:443/v1/responses';

/// One authenticated socket per user request, shared by every tool round.
/// The caller retains the full transcript for reconnects; cached IDs never
/// escape this connection or become part of persisted book history.
class ChatGptResponsesSocket {
  ChatGptResponsesSocket({
    required Future<WebSocket> Function() connect,
    required bool Function() isCurrent,
    this.eventTimeout = const Duration(minutes: 2),
    this.connectTimeout = const Duration(seconds: 30),
    this.onRequest,
  })  : _connect = connect,
        _isCurrent = isCurrent;

  final Future<WebSocket> Function() _connect;
  final bool Function() _isCurrent;
  final Duration eventTimeout;
  final Duration connectTimeout;
  final void Function(bool continuation, int inputItems)? onRequest;
  WebSocket? _socket;
  StreamIterator<dynamic>? _events;
  bool _closed = false, _busy = false;
  String? _previousId, _options;
  List<String> _prefix = [];

  void _guard() {
    if (_closed || !_isCurrent()) {
      throw const ChatGptError('Request canceled.');
    }
  }

  void _disconnect() {
    _previousId = null;
    _options = null;
    _prefix = [];
    final events = _events;
    final socket = _socket;
    _events = null;
    _socket = null;
    if (events != null) unawaited(events.cancel());
    if (socket != null) unawaited(socket.close());
  }

  void close() {
    _closed = true;
    _disconnect();
  }

  Stream<Map<String, dynamic>> send(
    List<Map<String, dynamic>> input,
    Map<String, dynamic> options,
  ) async* {
    _guard();
    if (_busy) {
      throw const ChatGptError('A ChatGPT response is already running.');
    }
    _busy = true;
    var completed = false;
    try {
      if (_socket == null) {
        var abandoned = false;
        final pending = _connect();
        // A timed-out/cancelled upgrade can still complete later. Do not leak
        // that authenticated socket after the request has been abandoned.
        unawaited(pending.then<void>((socket) {
          if (abandoned || _closed || !_isCurrent()) {
            unawaited(socket.close());
          }
        }, onError: (Object _, StackTrace __) {}));
        final socket = await pending.timeout(connectTimeout, onTimeout: () {
          abandoned = true;
          throw const SocketException('ChatGPT WebSocket connection timed out');
        });
        if (_closed || !_isCurrent()) {
          unawaited(socket.close());
          _guard();
        }
        socket.pingInterval = const Duration(seconds: 20);
        _socket = socket;
        _events = StreamIterator(socket);
      }
      final encodedInput = input.map(jsonEncode).toList();
      final encodedOptions = jsonEncode(options);
      var continuation = _previousId != null &&
          _options == encodedOptions &&
          _prefix.length <= encodedInput.length;
      if (continuation) {
        for (var i = 0; i < _prefix.length; i++) {
          if (_prefix[i] != encodedInput[i]) {
            continuation = false;
            break;
          }
        }
      }
      var recoveredCacheMiss = false;
      while (true) {
        _guard();
        onRequest?.call(continuation,
            continuation ? input.length - _prefix.length : input.length);
        _socket!.add(jsonEncode({
          ...options,
          'type': 'response.create',
          'store': false,
          'input': continuation ? input.skip(_prefix.length).toList() : input,
          if (continuation) 'previous_response_id': _previousId,
        }));
        final outputItems = <Map<String, dynamic>>[];
        var receivedOutput = false;
        while (true) {
          final available = await _events!.moveNext().timeout(eventTimeout);
          _guard();
          if (!available) {
            throw const SocketException(
                'ChatGPT WebSocket closed before completion');
          }
          final frame = _events!.current;
          if (frame is! String || utf8.encode(frame).length > 4 * 1024 * 1024) {
            throw const ChatGptError(
                'Invalid or oversized ChatGPT WebSocket event.');
          }
          final raw = jsonDecode(frame);
          if (raw is! Map<String, dynamic> || raw['type'] is! String) {
            throw const ChatGptError('Invalid ChatGPT WebSocket event.');
          }
          final error = raw['error'];
          final code = error is Map ? error['code'] : raw['code'];
          if (raw['type'] == 'error' &&
              code == 'previous_response_not_found' &&
              continuation &&
              !recoveredCacheMiss &&
              !receivedOutput) {
            _previousId = null;
            _prefix = [];
            continuation = false;
            recoveredCacheMiss = true;
            break;
          }
          if (raw['type'] == 'response.output_item.done' &&
              raw['item'] is Map) {
            outputItems.add(Map<String, dynamic>.from(raw['item'] as Map));
          }
          if (raw['type'] == 'response.output_text.delta' ||
              raw['type'] == 'response.output_item.done') {
            receivedOutput = true;
          }
          if (raw['type'] == 'response.completed') {
            final response = raw['response'];
            final id = response is Map ? response['id'] : null;
            final output = response is Map && response['output'] is List
                ? response['output'] as List
                : outputItems;
            _previousId = id is String && id.isNotEmpty ? id : null;
            _options = encodedOptions;
            _prefix = [...encodedInput, ...output.map(jsonEncode)];
            completed = true;
            yield raw;
            return;
          }
          yield raw;
          if (['error', 'response.failed', 'response.incomplete']
              .contains(raw['type'])) {
            return;
          }
        }
      }
    } finally {
      if (!completed) _disconnect();
      _busy = false;
    }
  }
}
