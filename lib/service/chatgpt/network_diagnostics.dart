import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'secure_transport.dart';

/// Fixed anonymous probes only. No auth token, callback, body or address is read.
class ChatGptNetworkDiagnostics {
  static const _channel = MethodChannel(
    'com.anxcye.anx_reader/network_diagnostics',
  );
  static Future<String> run() async {
    final results = <String, String>{};
    Future<void> probe(String key, Future<String> Function() action) async {
      try {
        results[key] = await action().timeout(const Duration(seconds: 10));
      } catch (e) {
        results[key] = diagnosticError(e);
      }
    }

    await Future.wait([
      probe('dart.https.default', () => _https(HttpClient())),
      probe('dart.https.recovery', () => _https(createChatGptHttpClient())),
      probe(
        'dart.https.control',
        () => _https(
          HttpClient(),
          endpoint: 'https://connectivitycheck.gstatic.com/generate_204',
        ),
      ),
      probe('dart.https.doh', _doh),
      probe('dart.dns', () async {
        final addresses = await InternetAddress.lookup('auth.openai.com');
        return 'ok v4=${addresses.where((a) => a.type == InternetAddressType.IPv4).length} v6=${addresses.where((a) => a.type == InternetAddressType.IPv6).length}';
      }),
      for (final family in [InternetAddressType.IPv4, InternetAddressType.IPv6])
        probe(
          family == InternetAddressType.IPv4 ? 'dart.tcp.v4' : 'dart.tcp.v6',
          () async {
            final addresses = await InternetAddress.lookup(
              'auth.openai.com',
              type: family,
            ).timeout(const Duration(seconds: 4));
            if (addresses.isEmpty) return 'no_address';
            Socket? socket;
            try {
              socket = await Socket.connect(
                addresses.first,
                443,
                timeout: const Duration(seconds: 3),
              );
              return 'ok';
            } finally {
              socket?.destroy();
            }
          },
        ),
      probe('dart.tcp.resolver', () async {
        final socket = await Socket.connect(
          InternetAddress('1.1.1.1'),
          443,
          timeout: const Duration(seconds: 4),
        );
        socket.destroy();
        return 'ok';
      }),
      probe('native', () async {
        final value = await _channel
            .invokeMethod<Object?>('probe')
            .timeout(const Duration(seconds: 10));
        final safe = sanitizeNativeDiagnostics(value);
        results.addAll(safe);
        return safe.isEmpty ? 'unavailable' : 'ok';
      }),
    ]);
    final keys = results.keys.toList()..sort();
    return 'Anx network diagnostics v1\n' +
        keys.map((k) => '$k: ${results[k]}').join('\n');
  }

  static Future<String> _doh() async {
    final client = HttpClient();
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final raw = await Socket.connect(
        InternetAddress('1.1.1.1'),
        443,
        timeout: const Duration(seconds: 4),
      );
      try {
        final socket = await SecureSocket.secure(
          raw,
          host: 'cloudflare-dns.com',
        ).timeout(const Duration(seconds: 4));
        return ConnectionTask.fromSocket(
          Future<Socket>.value(socket),
          socket.destroy,
        );
      } catch (_) {
        raw.destroy();
        rethrow;
      }
    };
    return _https(
      client,
      endpoint:
          'https://cloudflare-dns.com/dns-query?name=auth.openai.com&type=A',
      dns: true,
    );
  }

  static Future<String> _https(
    HttpClient client, {
    String endpoint =
        'https://auth.openai.com/.well-known/openid-configuration',
    bool dns = false,
  }) async {
    client.connectionTimeout = const Duration(seconds: 5);
    Timer? timer;
    try {
      timer = Timer(
        const Duration(seconds: 8),
        () => client.close(force: true),
      );
      final request = await client.getUrl(Uri.parse(endpoint));
      request.followRedirects = false;
      if (dns) request.headers.set('accept', 'application/dns-json');
      final response = await request.close().timeout(
        const Duration(seconds: 7),
      );
      // Status alone is sufficient. Do not read or log the response body.
      return 'http_${response.statusCode}';
    } finally {
      timer?.cancel();
      client.close(force: true);
    }
  }
}

String diagnosticError(Object error) {
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    return code == null ? 'socket' : 'socket errno=$code';
  }
  if (error is HandshakeException) return 'tls';
  if (error is TimeoutException) return 'timeout';
  if (error is MissingPluginException) return 'unavailable';
  if (error is PlatformException) return 'native_error';
  return 'error';
}

Map<String, String> sanitizeNativeDiagnostics(Object? value) {
  const keys = {
    'native.https',
    'native.control',
    'native.dns',
    'native.network',
    'native.validated',
    'native.internet',
    'native.vpn',
    'native.metered',
    'native.background',
    'native.appBackgroundRestricted',
    'native.accessNetworkState',
  };
  final result = <String, String>{};
  if (value is! Map) return result;
  for (final entry in value.entries) {
    if (entry.key is! String ||
        !keys.contains(entry.key) ||
        entry.value is! String)
      continue;
    final text = entry.value as String;
    if (RegExp(
      r'^(ok|unknown|denied|yes|no|none|enabled|disabled|whitelisted|unavailable|tls|timeout|dns|connect|error|http_[1-5][0-9]{2}|socket errno=-?[0-9]{1,6}|ok v4=[0-9]{1,3} v6=[0-9]{1,3})$',
    ).hasMatch(text))
      result[entry.key as String] = text;
  }
  return result;
}
