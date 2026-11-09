import 'dart:convert';
import '../lib/service/chatgpt/protocol.dart';

int checks = 0;
void check(bool ok, String name) {
  if (!ok) throw StateError(name);
  checks++;
}

Future<void> fails(Future<void> Function() action, String name) async {
  try {
    await action();
  } catch (_) {
    checks++;
    return;
  }
  throw StateError('Expected rejection: $name');
}

Future<void> main() async {
  check(
    pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk') ==
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    'RFC7636 PKCE',
  );
  final randoms = List.generate(20, (_) => randomOAuthValue());
  check(
    randoms.toSet().length == 20 &&
        randoms.every((s) => RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(s)),
    'secure values',
  );
  Uri cb(String query) =>
      Uri.parse('http://127.0.0.1:123/auth/callback?$query');
  check(
    validateCallback(cb('state=S&code=C&client_id=oaiapp_ABC'), state: 'S') ==
        'oaiapp_ABC',
    'new client',
  );
  check(
    validateCallback(
          cb('state=S&code=C'),
          state: 'S',
          issuedClientId: 'oaiapp_OLD',
        ) ==
        'oaiapp_OLD',
    'return client',
  );
  for (final query in [
    'state=bad&code=C&client_id=oaiapp_X',
    'code=C&client_id=oaiapp_X',
    'state=S&state=S&code=C&client_id=oaiapp_X',
    'state=S&error=access_denied&code=C&client_id=oaiapp_X',
    'state=S&code=C',
    'state=S&code=&client_id=oaiapp_X',
    'state=S&code=C&client_id=dynamic_agent_client',
    'state=S&code=C&code=D&client_id=oaiapp_X',
  ]) {
    await fails(() async {
      validateCallback(cb(query), state: 'S');
    }, query);
  }
  check(
    validateCallback(
          cb('state=S&code=C&client_id=opaque.issued-id'),
          state: 'S',
        ) ==
        'opaque.issued-id',
    'opaque issued client',
  );
  await fails(() async {
    validateCallback(cb('state=S&code=C&client_id=a&client_id=b'), state: 'S');
  }, 'duplicate client');
  await fails(() async {
    validateCallback(
      cb('state=S&code=C&client_id=oaiapp_OTHER'),
      state: 'S',
      issuedClientId: 'oaiapp_OLD',
    );
  }, 'swapped client');
  final now = DateTime.fromMillisecondsSinceEpoch(1000000);
  final claims = <String, dynamic>{
    'iss': 'https://auth.openai.com',
    'aud': ['oaiapp_A'],
    'sub': 'U',
    'nonce': 'N',
    'iat': 990,
    'exp': 1010,
  };
  validateIdentityClaims(claims, clientId: 'oaiapp_A', nonce: 'N', now: now);
  checks++;
  for (final change in <Map<String, dynamic>>[
    {'iss': 'https://evil.test'},
    {'aud': 'other'},
    {'nonce': 'bad'},
    {'sub': ''},
    {'sub': null},
    {'exp': 994},
    {'exp': '1010'},
    {'iat': 1006},
    {'iat': null},
    {'nbf': 1006},
    {
      'aud': ['oaiapp_A', 'other'],
    },
    {
      'aud': ['oaiapp_A', 'other'],
      'azp': 'other',
    },
  ]) {
    await fails(() async {
      validateIdentityClaims(
        {...claims, ...change},
        clientId: 'oaiapp_A',
        nonce: 'N',
        now: now,
      );
    }, 'invalid identity $change');
  }
  await fails(() async {
    validateIdentityClaims(
      claims,
      clientId: 'oaiapp_A',
      nonce: 'N',
      expectedSubject: 'OTHER',
      now: now,
    );
  }, 'swapped subject');
  final sse =
      ':keepalive\r\ndata: {"type":"response.output_text.delta",\r\ndata: "delta":"Привет"}\r\n\r\ndata: {"type":"response.output_text.delta","delta":"!"}\n\ndata: {"type":"response.completed"}\n\ndata: [DONE]\n\n';
  final bytes = utf8.encode(sse);
  final outputs = await chatGptText(
    decodeChatGptEvents(Stream.fromIterable(bytes.map((b) => [b]))),
  ).toList();
  check(
    outputs.join('|') == 'Привет|Привет!',
    'fragmented UTF8 CRLF SSE aggregation',
  );
  final eofEvents = await decodeChatGptEvents(
    Stream.value(utf8.encode('data: {"type":"response.completed"}')),
  ).toList();
  check(eofEvents.single['type'] == 'response.completed', 'SSE EOF frame');
  await fails(() async {
    await chatGptText(
      Stream.fromIterable([
        {'type': 'response.output_text.delta', 'delta': 'partial'},
      ]),
    ).toList();
  }, 'truncated stream');
  await fails(() async {
    await chatGptText(
      Stream.fromIterable([
        {'type': 'response.output_text.delta', 'delta': 'partial'},
        {
          'type': 'response.failed',
          'response': {
            'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
          },
        },
      ]),
    ).toList();
  }, 'late failure');
  await fails(() async {
    await chatGptText(Stream.value({'type': 'response.incomplete'})).toList();
  }, 'incomplete');
  await fails(() async {
    await chatGptText(
      Stream.value({
        'type': 'error',
        'code': 'subscription_sharing_usage_unavailable',
      }),
    ).toList();
  }, 'SSE error');
  final hidden = chatGptApiError({
    'error': {'code': 'bad token SECRET', 'message': 'SECRET'},
  }, status: 400).toString();
  check(
    !hidden.contains('SECRET') && hidden.contains('request_failed'),
    'server descriptions not exposed',
  );
  print('$checks protocol checks passed');
}
