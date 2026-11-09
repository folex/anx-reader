import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/secure_transport.dart';

void main() {
  final certDir = Platform.environment['ANX_TLS_TEST_DIR'] ?? '${Directory.systemTemp.path}/anx-transport-cert';
  final cert = '$certDir/cert.pem';
  final key = '$certDir/key.pem';
  test(
    'HttpClient sends original Host over trusted address socket TLS',
    () async {
      final serverContext = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      final clientContext = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(
          '$certDir/ca.pem',
        );
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      final seen = Completer<String>();
      server.listen((r) async {
        seen.complete(r.headers.value('host')!);
        r.response.write('OK');
        await r.response.close();
      });
      final client = HttpClient();
      client.connectionFactory = (uri, _, __) async {
        final raw = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        final secure = await secureChatGptSocket(
          raw,
          uri.host,
          context: clientContext,
        );
        return ConnectionTask.fromSocket(
          Future<Socket>.value(secure),
          secure.destroy,
        );
      };
      try {
        final response = await (await client.getUrl(
          Uri.parse('https://localhost:${server.port}/test'),
        )).close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        expect(await seen.future, 'localhost:${server.port}');
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test(
    'same trusted CA rejects wrong original hostname and untrusted root',
    () async {
      final sc = SecurityContext()
        ..useCertificateChain(cert)
        ..usePrivateKey(key);
      final trusted = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(
          '$certDir/ca.pem',
        );
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        sc,
      );
      final sub = server.listen((s) => s.destroy(), onError: (_) {});
      try {
        for (final pair in [
          ('wrong.example', trusted),
          ('localhost', SecurityContext(withTrustedRoots: false)),
        ]) {
          final raw = await Socket.connect(
            InternetAddress.loopbackIPv4,
            server.port,
          );
          await expectLater(
            secureChatGptSocket(raw, pair.$1, context: pair.$2),
            throwsA(isA<HandshakeException>()),
          );
        }
      } finally {
        await sub.cancel();
        await server.close();
      }
    },
  );
  test(
    'cancel before connect completion destroys late socket and sends no bytes',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<Socket>();
      final subscription = server.listen(accepted.complete);
      final pending = Completer<Socket>();
      final started = Completer<void>();
      final task = await chatGptConnection(
        Uri.parse('https://auth.openai.com'),
        null,
        null,
        connectNormally: (_, __) { started.complete(); return pending.future; },
      );
      final rejection = expectLater(
        task.socket,
        throwsA(isA<SocketException>()),
      );
      await started.future;
      task.cancel();
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final peer = await accepted.future;
      pending.complete(client);
      await rejection;
      final bytes = await peer.fold<int>(
        0,
        (total, chunk) => total + chunk.length,
      );
      expect(bytes, 0);
      peer.destroy();
      await subscription.cancel();
      await server.close();
    },
  );
  test('TLS certificate error never enters alternate DNS recovery', () async {
    var calls = 0;
    final task = await chatGptConnection(
      Uri.parse('https://auth.openai.com'),
      null,
      null,
      connectNormally: (_, __) async {
        calls++;
        throw const HandshakeException('rejected');
      },
    );
    await expectLater(task.socket, throwsA(isA<HandshakeException>()));
    expect(calls, 1);
  });
  test('DNS answers accept public IPs only and do not follow CNAME data', () {
    final body = {
      'Status': 0,
      'Answer': [
        for (final ip in [
          '104.18.1.1',
          '127.0.0.1',
          '10.0.0.1',
          '192.168.1.1',
          '169.254.1.1',
        ])
          {'type': 1, 'data': ip},
        {'type': 5, 'data': 'example.test'},
      ],
    };
    expect(parseDnsAddresses(body, 'A').map((a) => a.address), ['104.18.1.1']);
    expect(
      parseDnsAddresses({'Status': 2, 'Answer': body['Answer']}, 'A'),
      isEmpty,
    );
  });
}
