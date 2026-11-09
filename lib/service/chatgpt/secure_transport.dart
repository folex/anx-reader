import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Recovery happens before HTTP headers/body: OAuth codes are never replayed.
HttpClient createChatGptHttpClient() =>
    HttpClient()..connectionFactory = chatGptConnection;

const _hosts = {'auth.openai.com', 'api.openai.com', 'chatgpt.com'};

Future<ConnectionTask<Socket>> chatGptConnection(
  Uri uri,
  String? proxyHost,
  int? proxyPort, {
  Future<Socket> Function(String host, int port)? connectNormally,
}) async {
  if (proxyHost != null) return Socket.startConnect(proxyHost, proxyPort!);
  if (uri.scheme != 'https' || uri.port != 443 || !_hosts.contains(uri.host)) {
    throw const SocketException('Unsupported ChatGPT transport destination');
  }
  var cancelled = false;
  Socket? socket;
  HttpClient? resolver;
  void check() {
    if (cancelled) throw const SocketException('Connection cancelled');
  }

  Future<Socket> connect() async {
    try {
      check();
      socket =
          await (connectNormally?.call(uri.host, uri.port) ??
              SecureSocket.connect(
                uri.host,
                uri.port,
                timeout: const Duration(seconds: 8),
              ));
      check();
      return socket!;
    } on SocketException {
      check();
      // Only public DNS questions go to the resolver, never credentials.
      resolver = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      resolver!.connectionFactory = (u, ph, pp) async {
        final raw = await Socket.connect(
          InternetAddress('1.1.1.1'),
          443,
          timeout: const Duration(seconds: 5),
        );
        socket = raw;
        check();
        final secure = await secureChatGptSocket(raw, 'cloudflare-dns.com');
        socket = secure;
        check();
        return ConnectionTask.fromSocket(
          Future<Socket>.value(secure),
          secure.destroy,
        );
      };
      try {
        final addresses = <InternetAddress>[];
        for (final type in ['A', 'AAAA']) {
          check();
          try {
            final request = await resolver!.getUrl(
              Uri.https('cloudflare-dns.com', '/dns-query', {
                'name': uri.host,
                'type': type,
              }),
            );
            request.followRedirects = false;
            request.headers.set('accept', 'application/dns-json');
            final response = await request.close().timeout(
              const Duration(seconds: 6),
            );
            if (response.statusCode != 200) continue;
            final bytes = <int>[];
            await for (final chunk in response.timeout(
              const Duration(seconds: 6),
            )) {
              bytes.addAll(chunk);
              if (bytes.length > 65536)
                throw const SocketException('DNS response too large');
            }
            addresses.addAll(
              parseDnsAddresses(jsonDecode(utf8.decode(bytes)), type),
            );
          } on IOException {
            check();
          } on TimeoutException {
            check();
          } on FormatException {
            check();
          }
        }
        for (final address in addresses.take(8)) {
          check();
          Socket? raw;
          try {
            raw = await Socket.connect(
              address,
              uri.port,
              timeout: const Duration(seconds: 3),
            );
            socket = raw;
            check();
          } on SocketException {
            raw?.destroy();
            continue;
          }
          // A certificate failure MUST NOT be bypassed or retried as plaintext.
          socket = await secureChatGptSocket(raw, uri.host);
          check();
          return socket!;
        }
        throw const SocketException('OpenAI network connection unavailable');
      } finally {
        resolver?.close(force: true);
        resolver = null;
      }
    } finally {
      if (cancelled) socket?.destroy();
    }
  }

  return ConnectionTask.fromSocket(Future<Socket>(connect), () {
    cancelled = true;
    socket?.destroy();
    resolver?.close(force: true);
  });
}

List<InternetAddress> parseDnsAddresses(dynamic body, String type) {
  if (body is! Map || body['Status'] != 0 || body['Answer'] is! List) return [];
  final result = <InternetAddress>[];
  for (final item in body['Answer'] as List) {
    if (item is! Map ||
        item['type'] != (type == 'A' ? 1 : 28) ||
        item['data'] is! String)
      continue;
    final ip = InternetAddress.tryParse(item['data'] as String);
    if (ip == null ||
        ip.isLoopback ||
        ip.isLinkLocal ||
        (type == 'A' && ip.type != InternetAddressType.IPv4) ||
        (type == 'AAAA' && ip.type != InternetAddressType.IPv6))
      continue;
    if (ip.type == InternetAddressType.IPv4) {
      final b = ip.rawAddress;
      if (b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          b[0] >= 224 ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 169 && b[1] == 254))
        continue;
    } else if ((ip.rawAddress[0] & 0xe0) != 0x20) {
      continue;
    }
    result.add(ip);
  }
  return result;
}

/// Original DNS hostname drives both SNI and platform certificate verification.
Future<SecureSocket> secureChatGptSocket(
  Socket raw,
  String hostname, {
  SecurityContext? context,
}) async {
  try {
    return await SecureSocket.secure(
      raw,
      host: hostname,
      context: context,
    ).timeout(const Duration(seconds: 8));
  } catch (_) {
    raw.destroy();
    rethrow;
  }
}
