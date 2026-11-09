import 'dart:async';
import 'dart:io';
import 'protocol.dart';

/// Never expose raw transport errors, request URLs or token-bearing diagnostics.
String chatGptConnectionError(Object error, {bool browserAuthorized = false}) {
  if (error is ChatGptError) return error.message;
  final phase = browserAuthorized
      ? 'Browser authorization received, but Anx could not finish connecting to OpenAI. '
      : '';
  if (error is SocketException) {
    return '${phase}Anx could not connect to OpenAI. Open Network diagnostics to investigate. Once connected, tap Resume sign-in.';
  }
  if (error is HandshakeException) {
    return '${phase}Could not establish a secure OpenAI connection. Check your network, VPN, and phone date, then try signing in again.';
  }
  if (error is TimeoutException) {
    return '${phase}OpenAI timed out. Check your network and try signing in again.';
  }
  return 'Could not complete the ChatGPT action. Try again later.';
}
