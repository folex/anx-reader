import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/extensions/book_text_export.dart';

List<int> epub({String href = 'second.xhtml'}) {
  final entries = {
    'META-INF/container.xml':
        '<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>',
    'OEBPS/book.opf':
        '<package><manifest><item id="second" href="$href"/><item id="first" href="first.xhtml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>',
    'OEBPS/first.xhtml':
        '<html><head><title>First</title></head><body><p>La <ruby>ira<rt>гнев</rt></ruby> se fue.<sup data-anx-edit-added="true">[1]</sup></p><aside>Hidden explanation</aside><script>steal()</script><p>Otro párrafo.</p></body></html>',
    'OEBPS/second.xhtml':
        '<html><head><title>Second</title></head><body>Después.</body></html>'
  };
  final zip = Archive();
  for (final e in entries.entries) {
    final b = utf8.encode(e.value);
    zip.addFile(ArchiveFile(e.key, b.length, b));
  }
  return ZipEncoder().encode(zip)!;
}

void main() {
  test('exports original EPUB text in spine order without generated hints', () {
    final chapters = decodeEpubText(epub());
    expect(chapters.map((c) => c['title']), ['First', 'Second']);
    expect(chapters.first['text'], contains('La ira se fue.'));
    expect(chapters.first['text'], contains('Otro párrafo.'));
    expect(chapters.first['text'], isNot(contains('гнев')));
    expect(chapters.first['text'], isNot(contains('[1]')));
    expect(chapters.first['text'], isNot(contains('Hidden')));
    expect(chapters.first['text'], isNot(contains('steal')));
  });
  test('chapter selection uses the exact source address and rejects ambiguity',
      () {
    final chapters = decodeEpubText(epub());
    expect(selectEpubChapter(chapters, 'first.xhtml')['title'], 'First');
    expect(selectEpubChapter(chapters, 'OEBPS/second.xhtml#paragraph')['title'],
        'Second');
    expect(
        () => selectEpubChapter(chapters, 'missing.xhtml'), throwsStateError);
    expect(
        () => selectEpubChapter([...chapters, chapters.first], 'first.xhtml'),
        throwsStateError);
  });
  test('rejects escaping archive paths instead of exporting arbitrary entries',
      () {
    expect(() => decodeEpubText(epub(href: '../../outside.xhtml')),
        throwsFormatException);
  });
}
