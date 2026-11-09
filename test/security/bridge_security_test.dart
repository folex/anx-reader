import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/utils/js/js_call.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('EPUB href, CFI and note data cannot execute bridge JavaScript', () async {
    const payloads = [
      "chapter.xhtml#');globalThis.compromised=true;//",
      r"quote\');globalThis.compromised=true;//",
      r'${globalThis.compromised=true}',
      "line\nbreak\r\t\u2028\u2029\"'\\",
      '¿Qué significa? Пример 😄',
    ];
    for (final payload in payloads) {
      final source = jsCall('goToHref', [payload]);
      final result = await Process.run('node', ['-e', '''
        globalThis.compromised=false;
        let received;
        const goToHref=value=>{received=value;};
        $source;
        if (globalThis.compromised) process.exit(2);
        process.stdout.write(JSON.stringify(received));
      ''']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(jsonDecode(result.stdout as String), payload);
    }
  });

  test('annotation maps preserve data without executing it', () async {
    final value = {'id': 7, 'note': "');globalThis.compromised=true;//", 'value': r'\"'};
    final source = jsCall('addAnnotation', [value]);
    final result = await Process.run('node', ['-e', '''
      globalThis.compromised=false;
      let received;
      const addAnnotation=value=>{received=value;};
      $source;
      if (globalThis.compromised) process.exit(2);
      process.stdout.write(JSON.stringify(received));
    ''']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(jsonDecode(result.stdout as String), value);
  });
}
