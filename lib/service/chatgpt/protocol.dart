import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

class ChatGptError implements Exception {
  const ChatGptError(this.message);
  final String message;
  @override
  String toString() => message;
}

String randomOAuthValue([int length = 32]) {
  final random = Random.secure();
  return base64UrlEncode(
    List.generate(length, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String pkceChallenge(String verifier) => base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');

/// This error deliberately excludes raw server descriptions, headers and tokens.
ChatGptError chatGptApiError(dynamic body, {int? status}) {
  final error = body is Map ? body['error'] : null;
  final code = error is Map ? error['code'] ?? error['type'] : error;
  final safeCode =
      code is String && RegExp(r'^[a-zA-Z0-9_]{1,100}$').hasMatch(code)
          ? code
          : 'request_failed';
  if (safeCode == 'subscription_sharing_usage_limit_exceeded') {
    return const ChatGptError(
      'ChatGPT subscription limit reached. Try later.',
    );
  }
  if (safeCode == 'subscription_sharing_usage_unavailable' || status == 503) {
    return const ChatGptError(
      'ChatGPT is temporarily unavailable. Your connection is saved; try later.',
    );
  }
  if (status == 401) {
    return ChatGptError(
      'ChatGPT rejected authorization ($safeCode). Reconnect your account.',
    );
  }
  return ChatGptError(
    'ChatGPT: $safeCode${status == null ? '' : ' (HTTP $status)'}.',
  );
}

/// SSE framing is independent of TCP chunks and supports CRLF and multiline data.
Stream<Map<String, dynamic>> decodeChatGptEvents(
  Stream<List<int>> bytes,
) async* {
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final value = data.join('\n');
        data.clear();
        if (value != '[DONE]') {
          final event = jsonDecode(value);
          if (event is Map<String, dynamic>) yield event;
        }
      }
    } else if (line.startsWith('data:')) {
      final value = line.substring(5);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
  // The final event may omit the separating blank line.
  if (data.isNotEmpty && data.join('\n') != '[DONE]') {
    final event = jsonDecode(data.join('\n'));
    if (event is Map<String, dynamic>) yield event;
  }
}

Stream<String> chatGptText(Stream<Map<String, dynamic>> events) async* {
  var text = '';
  var completed = false;
  await for (final event in events) {
    switch (event['type']) {
      case 'response.output_text.delta':
        text += event['delta'] as String? ?? '';
        yield text;
      case 'response.completed':
        completed = true;
      case 'response.failed':
        throw chatGptApiError(event['response']);
      case 'error':
        throw chatGptApiError({'error': event['error'] ?? event});
      case 'response.incomplete':
        throw const ChatGptError(
          'ChatGPT did not finish the response. Try again.',
        );
    }
  }
  if (!completed) {
    throw const ChatGptError(
        'Connection interrupted before the response completed.');
  }
}

Map<String, dynamic> validateIdentityClaims(
  Map<String, dynamic> claims, {
  required String clientId,
  required String nonce,
  String? expectedSubject,
  DateTime? now,
}) {
  final time = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final audience = claims['aud'];
  if (claims['iss'] != 'https://auth.openai.com' ||
      !(audience == clientId ||
          (audience is List && audience.contains(clientId))) ||
      (audience is List && audience.length > 1 && claims['azp'] != clientId) ||
      claims['nonce'] != nonce ||
      claims['exp'] is! num ||
      claims['iat'] is! num ||
      (claims['exp'] as num) < time - 5 ||
      (claims['iat'] as num) > time + 5 ||
      (claims['nbf'] is num && (claims['nbf'] as num) > time + 5) ||
      claims['sub'] is! String ||
      (claims['sub'] as String).isEmpty ||
      (expectedSubject != null && claims['sub'] != expectedSubject)) {
    throw const ChatGptError('Could not verify the ChatGPT account identity.');
  }
  return claims;
}

String validateCallback(
  Uri callback, {
  required String state,
  String? issuedClientId,
}) {
  if (callback.queryParametersAll['state']?.length != 1 ||
      callback.queryParameters['state'] != state) {
    throw const ChatGptError('Invalid or expired authorization response.');
  }
  if (callback.queryParameters.containsKey('error')) {
    throw const ChatGptError('ChatGPT sign-in was canceled or denied.');
  }
  final client = callback.queryParameters['client_id'] ?? issuedClientId;
  if (client == null ||
      client.isEmpty ||
      client.length > 512 ||
      client == 'dynamic_agent_client' ||
      !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(client) ||
      (callback.queryParametersAll['client_id']?.length ?? 0) > 1 ||
      (issuedClientId != null && client != issuedClientId) ||
      callback.queryParametersAll['code']?.length != 1 ||
      callback.queryParameters['code']!.isEmpty) {
    throw const ChatGptError('ChatGPT did not complete app registration.');
  }
  return client;
}
