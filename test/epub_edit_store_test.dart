import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/reader_edits/epub_edit_store.dart';
import 'package:xml/xml.dart';

const original =
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Uno</title></head><body><p>La ira se fue. <em>Hola</em>.</p></body></html>';
String edited(String word) =>
    original.replaceFirst('La ira', '<ruby>La ira<rt>$word</rt></ruby>');
void main() {
  late Directory dir;
  late File file;
  late EpubEditStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('epub-store-test-');
    file = File('${dir.path}/book.epub');
    store = EpubEditStore();
    make(file);
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });
  test('image asset and XHTML commit together, original resources and manifest preserved', () async {
    final source = file.readAsBytesSync();
    final bytes = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 1)));
    final assetPath = 'OEBPS/anx-images/${crypto.sha256.convert(bytes)}.png';
    final snapshot = await store.readChapter(file: file, chapterHref: 'OEBPS/chapter.xhtml');
    final updated = original.replaceFirst('</body>', '<figure data-anx-edit-added="illustration"><img src="anx-images/${crypto.sha256.convert(bytes)}.png" alt="Example"/><figcaption>Illustration</figcaption></figure></body>');
    await store.commit(snapshot: snapshot, xhtml: updated, isCurrent: () => true,
      images: [EpubImageAsset(path: assetPath, bytes: bytes)]);
    final zip = ZipDecoder().decodeBytes(file.readAsBytesSync());
    expect(zip.findFile(assetPath)!.content, bytes);
    expect(File('${file.path}.anx-edit.bak').readAsBytesSync(), source);
    final opf = XmlDocument.parse(utf8.decode(zip.findFile('OEBPS/book.opf')!.content as List<int>));
    final item = opf.descendants.whereType<XmlElement>().singleWhere((e) => e.getAttribute('href') == 'anx-images/${crypto.sha256.convert(bytes)}.png');
    expect(item.getAttribute('media-type'), 'image/png');
    expect(item.namespaceUri, 'http://www.idpf.org/2007/opf');
    final next = await store.readChapter(file: file, chapterHref: 'OEBPS/chapter.xhtml');
    expect(next.packagePath, 'OEBPS/book.opf');
    final resource = await store.readImage(snapshot: next, href: 'anx-images/${crypto.sha256.convert(bytes)}.png');
    expect(resource, bytes);
    final saved = file.readAsBytesSync();
    expect(() => store.readImage(snapshot: next, href: 'https://example.com/a.png'), throwsA(isA<EpubEditException>()));
    expect(file.readAsBytesSync(), saved);
  });
  test('canceled image commit leaves neither asset nor XHTML change', () async {
    final source = file.readAsBytesSync();
    final snapshot = await store.readChapter(file: file, chapterHref: 'OEBPS/chapter.xhtml');
    expect(() => store.commit(snapshot: snapshot, xhtml: edited('test'), isCurrent: () => false,
      images: [EpubImageAsset(path:'OEBPS/anx-images/a.png',bytes:Uint8List.fromList([1,2]))]), throwsA(isA<EpubEditException>()));
    expect(file.readAsBytesSync(), source);
  });
  test(
    'atomic edit, single backup, mimetype first stored, asset raw preserved',
    () async {
      final before = file.readAsBytesSync();
      final raw = rawAsset(file);
      final storedRaw = rawAsset(file, 'OEBPS/stored.bin');
      final snapshot = await store.readChapter(
        file: file,
        chapterHref: 'OEBPS/chapter.xhtml#p1',
      );
      expect(snapshot.bookIdentifier, 'urn:test:book');
      final result = await store.commit(
        snapshot: snapshot,
        xhtml: edited('гнев'),
        isCurrent: () => true,
      );
      expect(result.changed, true);
      expect(File(result.backupPath!).readAsBytesSync(), before);
      expect(rawAsset(file), raw);
      expect(rawAsset(file, 'OEBPS/stored.bin'), storedRaw);
      final input = InputFileStream(file.path);
      try {
        final d = ZipDirectory.read(input);
        expect(d.fileHeaders.first.filename, 'mimetype');
        expect(d.fileHeaders.first.compressionMethod, 0);
      } finally {
        input.closeSync();
      }
      final next = await store.readChapter(
        file: file,
        chapterHref: 'OEBPS/chapter.xhtml',
      );
      final old = file.readAsBytesSync();
      await store.commit(
        snapshot: next,
        xhtml: next.xhtml.replaceFirst('гнев', 'ярость'),
        isCurrent: () => true,
      );
      expect(File(result.backupPath!).readAsBytesSync(), old);
      expect(dir.listSync().whereType<File>().length, 2);
    },
  );
  test(
    'concurrent stale edits permit one writer, preserve winner and backup',
    () async {
      final snapshot = await store.readChapter(
        file: file,
        chapterHref: 'OEBPS/chapter.xhtml',
      );
      final jobs = [
        store.commit(
          snapshot: snapshot,
          xhtml: edited('первое'),
          isCurrent: () => true,
        ),
        store.commit(
          snapshot: snapshot,
          xhtml: edited('второе'),
          isCurrent: () => true,
        ),
      ];
      final outcomes = await Future.wait(
        jobs.map((job) async {
          try {
            return (await job).changed;
          } catch (_) {
            return false;
          }
        }),
      );
      expect(outcomes.where((x) => x).length, 1);
      expect(
        (await store.readChapter(
          file: file,
          chapterHref: 'OEBPS/chapter.xhtml',
        )).xhtml,
        contains('первое'),
      );
    },
  );
  test('changed book scope or source text cannot touch original', () async {
    final snapshot = await store.readChapter(
      file: file,
      chapterHref: 'OEBPS/chapter.xhtml',
    );
    final before = file.readAsBytesSync();
    await expectLater(
      store.commit(
        snapshot: snapshot,
        xhtml: edited('гнев'),
        isCurrent: () => false,
      ),
      throwsA(isA<EpubEditException>()),
    );
    await expectLater(
      store.commit(
        snapshot: snapshot,
        xhtml: original.replaceFirst('ira', 'amor'),
        isCurrent: () => true,
      ),
      throwsA(isA<EpubEditException>()),
    );
    await expectLater(
      store.commit(snapshot: snapshot, xhtml: '<html>', isCurrent: () => true),
      throwsA(isA<EpubEditException>()),
    );
    expect(file.readAsBytesSync(), before);
    expect(dir.listSync().length, 1);
  });
  test(
    'scope changing immediately before write aborts; no temporary files',
    () async {
      final snapshot = await store.readChapter(
        file: file,
        chapterHref: 'OEBPS/chapter.xhtml',
      );
      final before = file.readAsBytesSync();
      var checks = 0;
      await expectLater(
        store.commit(
          snapshot: snapshot,
          xhtml: edited('гнев'),
          isCurrent: () => ++checks < 3,
        ),
        throwsA(isA<EpubEditException>()),
      );
      expect(file.readAsBytesSync(), before);
      expect(dir.listSync().length, 1);
    },
  );
  test(
    'EPUB2 upgrade preserves namespace, spine, metadata and marks script',
    () async {
      make(file, version: '2.0');
      final snapshot = await store.readChapter(
        file: file,
        chapterHref: 'OEBPS/chapter.xhtml',
      );
      final html = edited('ярость').replaceFirst(
        '</head>',
        '<script type="text/javascript">/* local runtime */</script></head>',
      );
      await store.commit(
        snapshot: snapshot,
        xhtml: html,
        isCurrent: () => true,
      );
      final zip = ZipDecoder().decodeBytes(file.readAsBytesSync());
      final opf = XmlDocument.parse(
        utf8.decode(zip.findFile('OEBPS/book.opf')!.content as List<int>),
      );
      expect(opf.rootElement.getAttribute('version'), '3.0');
      expect(opf.rootElement.namespaceUri, 'http://www.idpf.org/2007/opf');
      expect(
        opf.descendants
            .whereType<XmlElement>()
            .firstWhere((e) => e.name.local == 'itemref')
            .getAttribute('idref'),
        'c1',
      );
      expect(
        opf.descendants
            .whereType<XmlElement>()
            .firstWhere((e) => e.name.local == 'title')
            .innerText,
        'Book title',
      );
      final item = opf.descendants.whereType<XmlElement>().firstWhere(
        (e) => e.getAttribute('id') == 'c1',
      );
      expect(item.getAttribute('properties'), contains('scripted'));
      expect(zip.findFile('OEBPS/anx-edit-nav.xhtml'), isNotNull);
      expect(
        opf.descendants
            .whereType<XmlElement>()
            .where(
              (e) =>
                  e.name.local == 'meta' &&
                  e.getAttribute('property') == 'dcterms:modified',
            )
            .length,
        1,
      );
    },
  );
  test(
    'symlink metadata, invalid XML and path traversal rejected before writes',
    () async {
      make(file, link: true);
      await expectLater(
        store.readChapter(file: file, chapterHref: 'OEBPS/chapter.xhtml'),
        throwsA(isA<EpubEditException>()),
      );
      make(file);
      await expectLater(
        store.readChapter(file: file, chapterHref: '../OEBPS/chapter.xhtml'),
        throwsA(isA<EpubEditException>()),
      );
      make(
        file,
        chapter:
            '<!DOCTYPE html [<!ENTITY x "boom">]><html><body>&x;</body></html>',
      );
      await expectLater(
        store.readChapter(file: file, chapterHref: 'OEBPS/chapter.xhtml'),
        throwsA(isA<EpubEditException>()),
      );
    },
  );
  test(
    'basic HTML doctype works and CDATA original text cannot be changed',
    () async {
      make(
        file,
        chapter:
            '<!DOCTYPE html>' +
            original.replaceFirst('La ira', '<![CDATA[La ira]]>'),
      );
      final snap = await store.readChapter(
        file: file,
        chapterHref: 'chapter.xhtml',
      );
      await expectLater(
        store.commit(
          snapshot: snap,
          xhtml: snap.xhtml.replaceFirst('ira', 'amor'),
          isCurrent: () => true,
        ),
        throwsA(isA<EpubEditException>()),
      );
      final next = snap.xhtml.replaceFirst(
        '<![CDATA[La ira]]>',
        '<ruby><![CDATA[La ira]]><rt>гнев</rt></ruby>',
      );
      expect(
        (await store.commit(
          snapshot: snap,
          xhtml: next,
          isCurrent: () => true,
        )).changed,
        true,
      );
    },
  );
  test(
    'external image does not prevent local spine edit, nonspine doc rejected',
    () async {
      make(file, remote: true);
      final snap = await store.readChapter(
        file: file,
        chapterHref: 'chapter.xhtml',
      );
      expect(
        (await store.commit(
          snapshot: snap,
          xhtml: edited('гнев'),
          isCurrent: () => true,
        )).changed,
        true,
      );
      make(file, nonSpine: true);
      await expectLater(
        store.readChapter(file: file, chapterHref: 'OEBPS/chapter.xhtml'),
        throwsA(isA<EpubEditException>()),
      );
    },
  );
  test(
    'source changed during backup preparation survives without replacement',
    () async {
      final snap = await store.readChapter(
        file: file,
        chapterHref: 'chapter.xhtml',
      );
      var checks = 0;
      await expectLater(
        store.commit(
          snapshot: snap,
          xhtml: edited('гнев'),
          isCurrent: () {
            checks++;
            if (checks == 4) file.writeAsStringSync('external change');
            return true;
          },
        ),
        throwsA(isA<EpubEditException>()),
      );
      expect(file.readAsStringSync(), 'external change');
      expect(dir.listSync().length, 1);
    },
  );
  test('lying uncompressed XML size cannot bypass bounded inflation', () async {
    make(
      file,
      chapter: original.replaceFirst(
        '</body>',
        List.filled(5 * 1024 * 1024, 'x').join() + '</body>',
      ),
    );
    final bytes = file.readAsBytesSync();
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length - 46; i++) {
      if (view.getUint32(i, Endian.little) != 0x02014b50) continue;
      final length = view.getUint16(i + 28, Endian.little);
      if (i + 46 + length > bytes.length) continue;
      if (utf8.decode(bytes.sublist(i + 46, i + 46 + length)) ==
          'OEBPS/chapter.xhtml') {
        view.setUint32(i + 24, 8, Endian.little);
        break;
      }
    }
    file.writeAsBytesSync(bytes);
    await expectLater(
      store.readChapter(file: file, chapterHref: 'chapter.xhtml'),
      throwsA(isA<EpubEditException>()),
    );
  });
  test(
    'no-op does not rotate backup and added note text is excluded from book text',
    () async {
      final snap = await store.readChapter(
        file: file,
        chapterHref: 'OEBPS/chapter.xhtml',
      );
      expect(
        (await store.commit(
          snapshot: snap,
          xhtml: snap.xhtml,
          isCurrent: () => true,
        )).changed,
        false,
      );
      final withNote = original.replaceFirst(
        '</body>',
        '<aside data-anx-edit-added="note">Перевод</aside></body>',
      );
      expect(
        (await store.commit(
          snapshot: snap,
          xhtml: withNote,
          isCurrent: () => true,
        )).changed,
        true,
      );
    },
  );
}

void make(
  File file, {
  String version = '3.0',
  bool link = false,
  bool remote = false,
  bool nonSpine = false,
  String chapter = original,
}) {
  final a = Archive();
  void add(String path, String content, {bool compress = true}) {
    final bytes = utf8.encode(content);
    a.addFile(ArchiveFile(path, bytes.length, bytes)..compress = compress);
  }

  add('mimetype', 'application/epub+zip', compress: false);
  add(
    'META-INF/container.xml',
    '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'OEBPS/book.opf',
    '<opf:package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="$version" unique-identifier="book-id"><opf:metadata><dc:identifier id="book-id">urn:test:book</dc:identifier><dc:title>Book title</dc:title></opf:metadata><opf:manifest>${remote ? '<opf:item id="remote" href="https://example.com/image.png" media-type="image/png"/>' : ''}<opf:item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/><opf:item id="img" href="cover.bin" media-type="image/jpeg"/></opf:manifest><opf:spine>${nonSpine ? '' : '<opf:itemref idref="c1"/>'}</opf:spine></opf:package>',
  );
  add('OEBPS/chapter.xhtml', chapter);
  a.addFile(
    ArchiveFile('OEBPS/cover.bin', 10000, List.generate(10000, (i) => i % 251)),
  );
  add(
    'OEBPS/stored.bin',
    'stored-content-' + List.filled(10000, 'a').join(),
    compress: false,
  );
  if (link)
    a.addFile(
      ArchiveFile('evil-link', 3, utf8.encode('abc'))
        ..mode = 0xa1ff
        ..isSymbolicLink = true
        ..nameOfLinkedFile = 'abc',
    );
  file.writeAsBytesSync(ZipEncoder().encode(a)!);
}

List<int> rawAsset(File file, [String name = 'OEBPS/cover.bin']) {
  final input = InputFileStream(file.path);
  try {
    final d = ZipDirectory.read(input);
    return d.fileHeaders
        .firstWhere((h) => h.filename == name)
        .file!
        .rawContent!
        .toUint8List();
  } finally {
    input.closeSync();
  }
}
