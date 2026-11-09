import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/service/ai/tools/reader_context_tool.dart';

void main() {
  test('selection tool reports no selection rather than inventing target', () {
    final data = readerContextResult({
      'visible': 'La ira lo dominaba.',
      'selection': '',
      'secret': 'token',
    }, selectionOnly: true);
    expect(data['hasSelection'], false);
    expect(data['selection'], '');
    expect(data['visible'], 'La ira lo dominaba.');
    expect(data.containsKey('secret'), false);
  });
  test('only bounded reader fields leave the local bridge', () {
    final data = readerContextResult(
      jsonEncode({
        'title': 'A' * 200,
        'chapterHref': 'c.xhtml',
        'visible': 'v' * 9000,
        'selection': 's' * 3000,
        'path': '/private/book.epub',
        'token': 'secret',
        'paragraphHash': 'a' * 64,
        'paragraphIndex': 7,
        'visibleTruncated': true,
      }),
      selectionOnly: false,
    );
    expect((data['visible'] as String).length, 6000);
    expect((data['selection'] as String).length, 2000);
    expect((data['title'] as String).length, 140);
    expect(data['viewAnchor']['paragraphIndex'], 7);
    expect(data['viewAnchor']['scope'], contains('first visible paragraph'));
    expect(data['visibleTruncated'], true);
    expect(jsonEncode(data), isNot(contains('secret')));
    expect(jsonEncode(data), isNot(contains('/private')));
  });
  test('malformed anchors are not presented as verified locations', () {
    for (final anchor in [
      {'paragraphHash': 'invented', 'paragraphIndex': 0},
      {'paragraphHash': 'a' * 64, 'paragraphIndex': -1},
      {'paragraphHash': 'a' * 64, 'paragraphIndex': '2'},
    ]) {
      final data = readerContextResult({
        ...anchor,
        'selection': 'ira',
      }, selectionOnly: true);
      expect(data.containsKey('viewAnchor'), false);
      expect(data['hasSelection'], true);
    }
  });
  test('invalid snapshot fails and never stringifies unknown objects', () {
    expect(
      () => readerContextResult(['not a snapshot'], selectionOnly: false),
      throwsFormatException,
    );
    expect(
      () => readerContextResult('not JSON', selectionOnly: false),
      throwsFormatException,
    );
    final data = readerContextResult({
      'selection': {'token': 'secret'},
    }, selectionOnly: true);
    expect(data['hasSelection'], false);
    expect(data['selection'], '');
  });
}
