import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/chatgpt/network_diagnostics.dart';

void main() {
  test('transport errors expose category and errno only', () {
    expect(
      diagnosticError(
        const SocketException(
          'secret https://host/code=token',
          osError: OSError('private ssid', 101),
        ),
      ),
      'socket errno=101',
    );
    expect(diagnosticError(const SocketException('token')), 'socket');
    expect(diagnosticError(HandshakeException('token')), 'tls');
    expect(diagnosticError(TimeoutException('token')), 'timeout');
    expect(
      diagnosticError(PlatformException(code: 'private', message: 'secret')),
      'native_error',
    );
    expect(diagnosticError(FormatException('secret')), 'error');
  });
  test('native report permits fixed keys and status values only', () {
    final result = sanitizeNativeDiagnostics({
      'native.https': 'http_200',
      'native.control': 'http_204',
      'native.dns': 'ok v4=2 v6=2',
      'native.network': 'ssid secret',
      'token': 'accesssecret',
      'native.vpn': 'no',
      'native.appBackgroundRestricted': 'yes',
    });
    expect(result, {
      'native.https': 'http_200',
      'native.control': 'http_204',
      'native.dns': 'ok v4=2 v6=2',
      'native.vpn': 'no',
      'native.appBackgroundRestricted': 'yes',
    });
    expect(sanitizeNativeDiagnostics('secret'), isEmpty);
    expect(
      sanitizeNativeDiagnostics({'native.https': 'http_200\nsecret'}),
      isEmpty,
    );
  });
}
