import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/network_error.dart';
import 'package:anx_reader/service/chatgpt/protocol.dart';

void main() {
  test('post-callback DNS error explains phase without raw data', () {
    final text = chatGptConnectionError(
      const SocketException('secret-token https://host/path?code=secret'),
      browserAuthorized: true,
    );
    expect(text, contains('Browser authorization received'));
    expect(text, contains('connect to OpenAI'));
    expect(text, isNot(contains('secret')));
  });
  test(
    'safe domain errors preserved; network and unexpected details sanitized',
    () {
      expect(
        chatGptConnectionError(const ChatGptError('Known safe message')),
        'Known safe message',
      );
      for (final error in [
        HandshakeException('secret'),
        TimeoutException('secret'),
        FormatException('secret'),
      ]) {
        expect(chatGptConnectionError(error), isNot(contains('secret')));
      }
    },
  );
}
