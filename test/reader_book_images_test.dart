import 'package:crypto/crypto.dart' as crypto;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:anx_reader/service/reader_edits/reader_book_images.dart';
import 'package:anx_reader/service/reader_edits/book_image_assets.dart';
import 'package:anx_reader/service/reader_edits/epub_edit_store.dart';

void main() {
  late Directory directory;
  late File file;
  late Uint8List original;
  late ReaderBookImages handler;
  var current = true;
  var generationCount = 0;
  setUp(() {
    current = true;
    generationCount = 0;
    directory = Directory.systemTemp.createTempSync('book-images-');
    file = File('${directory.path}/book.epub');
    final image = img.Image(width: 2, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 255, 255, 255, 255)
      ..setPixelRgba(1, 0, 0, 0, 0, 128);
    original = Uint8List.fromList(img.encodePng(image));
    final archive = Archive();
    void text(String name, String value) => archive.addFile(
        ArchiveFile(name, utf8.encode(value).length, utf8.encode(value)));
    text('mimetype', 'application/epub+zip');
    text('META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>');
    text('OPS/book.opf',
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">book</dc:identifier></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="image" href="diagram.png" media-type="image/png"/></manifest><spine><itemref idref="chapter"/></spine></package>');
    text('OPS/chapter.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Book</title></head><body><p>La ira se fue.</p><img src="diagram.png" alt="Drawing"/></body></html>');
    archive.addFile(ArchiveFile('OPS/diagram.png', original.length, original));
    file.writeAsBytesSync(ZipEncoder().encode(archive)!);
    handler = ReaderBookImages(
        file: file,
        chapterHref: 'OPS/chapter.xhtml',
        vault: BookImageVault('book-account', root: directory),
        current: () => current,
        prepareInsertion: (_, __) async => throw UnimplementedError(),
        visibleIndices: () async => [0],
        generate: (_, beforeSend) async {
          await beforeSend();
          generationCount++;
          return original;
        },
        save: (snapshot, edit, images) async {
          final result = await EpubEditStore().commit(
              snapshot: snapshot,
              xhtml: edit['xhtml'],
              isCurrent: () => current,
              images: images);
          return {'changed': result.changed};
        });
  });
  tearDown(() => directory.deleteSync(recursive: true));
  test(
      'local dark edit preserves original, writes variant, retries once and restores',
      () async {
    final listed = await handler.handle({'action': 'list'});
    final info = (listed['images'] as List).single as Map;
    expect(info['visible'], true);
    final input = {
      'action': 'edit',
      'operationId': 'dark1',
      'imageId': info['imageId'],
      'target': 'dark',
      'filters': {'preset': 'dark-paper'}
    };
    expect((await handler.handle(input))['changed'], true);
    final zip = ZipDecoder().decodeBytes(file.readAsBytesSync());
    expect(zip.findFile('OPS/diagram.png')!.content, original);
    final snapshot = await EpubEditStore()
        .readChapter(file: file, chapterHref: 'OPS/chapter.xhtml');
    final entry = bookImageEntries(snapshot).single;
    expect(entry.element.getAttribute('src'), 'diagram.png');
    expect(entry.element.getAttribute('data-anx-image-dark-src'), isNotNull);
    final dark = await EpubEditStore().readImage(
        snapshot: snapshot,
        href: entry.element.getAttribute('data-anx-image-dark-src')!);
    expect(img.decodePng(dark)!.getPixel(0, 0).r, lessThan(10));
    final saved = file.readAsBytesSync();
    expect((await handler.handle(input))['changed'], false);
    expect(file.readAsBytesSync(), saved);
    expect(() => handler.handle({...input, 'operationId': 'stale'}),
        throwsA(isA<EpubEditException>()));
    await handler.handle({
      'action': 'edit',
      'operationId': 'restore',
      'imageId': entry.id,
      'target': 'all',
      'restore': true
    });
    final restored = bookImageEntries(await EpubEditStore()
            .readChapter(file: file, chapterHref: 'OPS/chapter.xhtml'))
        .single;
    expect(restored.element.getAttribute('src'), 'diagram.png');
    expect(restored.element.getAttribute('data-anx-image-dark-src'), isNull);
  });
  test('uncertain prior paid generation is not submitted again', () async {
    await BookImageVault('book-account', root: directory).startGeneration(
        'uncertain',
        crypto.sha256.convert(utf8.encode('one picture')).toString());
    expect(
        () => handler.handle({
              'action': 'generate',
              'operationId': 'uncertain',
              'prompt': 'one picture'
            }),
        throwsA(isA<EpubEditException>()));
    expect(generationCount, 0);
  });
  test(
      'generated/imported images are private assets available for insertion, scope cancellation prevents EPUB writes',
      () async {
    final before = file.readAsBytesSync();
    final generated = await handler.handle({
      'action': 'generate',
      'operationId': 'generation-1',
      'prompt': 'a period costume'
    });
    final id = generated['imageId'] as String;
    final cached = await handler.handle({
      'action': 'generate',
      'operationId': 'generation-1',
      'prompt': 'a period costume'
    });
    expect(cached['imageId'], id);
    expect(generationCount, 1);
    expect(
        () => handler.handle({
              'action': 'generate',
              'operationId': 'generation-1',
              'prompt': 'different picture'
            }),
        throwsA(isA<EpubEditException>()));
    expect(generationCount, 1);
    expect(await BookImageVault('book-account', root: directory).get(id),
        isNotEmpty);
    expect(() => BookImageVault('other-account', root: directory).get(id),
        throwsA(isA<EpubEditException>()));
    current = false;
    expect(() => handler.handle({'action': 'list'}),
        throwsA(isA<EpubEditException>()));
    expect(file.readAsBytesSync(), before);
  });
}
