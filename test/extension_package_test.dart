import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/extensions/extension_package.dart';

List<int> package({Map<String, dynamic>? changes, Map<String, String>? extra}) {
  final manifest = {
    'apiVersion': 1,
    'id': 'notebooklm',
    'name': 'NotebookLM',
    'version': '0.1.0',
    'permissions': ['books.read', 'network', 'ui'],
    'origins': ['https://notebook.google.com'],
    'authUrl': 'https://notebook.google.com/',
    'tools': [
      {
        'name': 'list',
        'description': 'List notebooks',
        'parameters': {'type': 'object'}
      }
    ],
    ...?changes
  };
  final a = Archive();
  for (final entry in {
    'manifest.json': jsonEncode(manifest),
    'plugin.js': 'module.exports={};',
    ...?extra
  }.entries) {
    final bytes = utf8.encode(entry.value);
    a.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(a)!;
}

void main() {
  test('loads tool declarations without executing extension code', () {
    final e = ReaderExtension.decode(package());
    expect(e.toolId('list'), 'ext_notebooklm_list');
    expect(e.origins, ['https://notebook.google.com']);
  });
  test(
      'rejects unsupported APIs, unsafe archive paths and undeclared auth origins',
      () {
    for (final bytes in [
      package(changes: {'apiVersion': 2}),
      package(extra: {'../escape': 'x'}),
      package(changes: {'authUrl': 'https://evil.example/login'}),
      package(changes: {
        'permissions': ['system.exec']
      }),
      package(changes: {
        'origins': ['http://notebook.google.com']
      }),
      package(changes: {
        'origins': ['https://notebook.google.com/path']
      })
    ]) {
      expect(() => ReaderExtension.decode(bytes), throwsFormatException);
    }
  });
  test('revoked permissions and origin tricks are rejected at invocation', () {
    final e = ReaderExtension.decode(package());
    final grants = {'network', 'books.read'};
    requireExtensionPermission(e, grants, 'network',
        url: 'https://notebook.google.com/path');
    for (final url in [
      'https://notebook.google.com.evil.example/',
      'https://notebook.google.com@evil.example/',
      'http://notebook.google.com/'
    ]) {
      expect(() => requireExtensionPermission(e, grants, 'network', url: url),
          throwsStateError);
    }
    grants.remove('books.read');
    expect(() => requireExtensionPermission(e, grants, 'books.read'),
        throwsStateError);
    expect(() => requireExtensionPermission(e, {'books.write'}, 'books.write'),
        throwsStateError);
  });
}
