import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

/// Original EPUB source text in reading order, without generated annotations.
/// PDF export needs a separate text-layer adapter; it is not silently OCRed.
Future<List<Map<String, String>>> exportEpubText(String filePath) async {
  if (!filePath.toLowerCase().endsWith('.epub')) {
    throw StateError(
        'Whole-book upload currently supports EPUB. Use the current chapter/page for PDF.');
  }
  final file = File(filePath);
  if (await file.length() > 100 * 1024 * 1024) {
    throw StateError('EPUB exceeds 100 MB');
  }
  final bytes = await file.readAsBytes();
  return decodeEpubText(bytes);
}

List<Map<String, String>> decodeEpubText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  String read(String name) {
    if (path.posix.isAbsolute(name) || name.startsWith('../')) {
      throw const FormatException('Unsafe EPUB path');
    }
    final entry = archive.findFile(name);
    if (entry == null || entry.size > 8 * 1024 * 1024) {
      throw FormatException('Missing or oversized EPUB entry: $name');
    }
    return utf8.decode(entry.content as List<int>, allowMalformed: true);
  }

  final container = XmlDocument.parse(read('META-INF/container.xml'));
  final rootfile = container.descendants
      .whereType<XmlElement>()
      .firstWhere((e) => e.name.local == 'rootfile')
      .getAttribute('full-path')!;
  final opf = XmlDocument.parse(read(rootfile));
  final items = {
    for (final e in opf.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'item'))
      e.getAttribute('id'): e.getAttribute('href')
  };
  final chapters = <Map<String, String>>[];
  var total = 0;
  for (final item in opf.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'itemref')) {
    if (item.getAttribute('linear') == 'no') continue;
    final href = items[item.getAttribute('idref')];
    if (href == null) continue;
    final name = path.posix.normalize(path.posix.join(
        path.posix.dirname(rootfile),
        Uri.decodeComponent(href.split('#').first)));
    final doc = html.parse(read(name));
    doc
        .querySelectorAll(
            'script,style,rt,rp,aside,[data-anx-edit-added],.rl-ui,.rl-ref,.rl-gloss,.reader-ru-ref,.learn-controls-static,[role="doc-noteref"]')
        .forEach((e) => e.remove());
    final body = doc.body;
    if (body == null) continue;
    for (final br in body.querySelectorAll('br')) {
      br.replaceWith(html.parseFragment('\n'));
    }
    for (final block in body.querySelectorAll('p,div,h1,h2,h3,li')) {
      block.append(html.parseFragment('\n'));
    }
    final text = body.text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (text.isEmpty) continue;
    total += text.length;
    if (total > 4 * 1024 * 1024) {
      throw StateError(
          'Book text exceeds 4 MB. Upload selected chapters instead.');
    }
    chapters.add({
      'href': name,
      'sourceHref': href,
      'title': doc.querySelector('h1,h2,title')?.text.trim() ?? name,
      'text': text
    });
  }
  if (chapters.isEmpty) throw StateError('No EPUB text found');
  return chapters;
}

Map<String, String> selectEpubChapter(
    List<Map<String, String>> chapters, String href) {
  String normalize(String value) => Uri.decodeComponent(value.split('#').first)
      .replaceFirst(RegExp(r'^/+'), '');
  final target = normalize(href);
  if (target.isEmpty) throw StateError('Current chapter is not ready');
  final exact = chapters
      .where((chapter) =>
          normalize(chapter['href']!) == target ||
          normalize(chapter['sourceHref']!) == target)
      .toList();
  if (exact.length == 1) return exact.single;
  throw StateError('Could not uniquely identify the current EPUB chapter');
}
