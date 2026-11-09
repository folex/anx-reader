import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/reader_edits/pdf_hint_store.dart';

void main() {
  late Directory dir;
  late File pdf;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('anx-pdf-hints');
    pdf = File('${dir.path}/book.pdf');
    await pdf.writeAsString('%PDF-1.7\nOriginal bytes');
  });
  tearDown(() async => dir.delete(recursive: true));
  final record = <String, dynamic>{
    'spec': {
      'operationId': 'n1',
      'type': 'footnote',
      'quote': 'ira',
      'text': 'anger'
    },
    'anchor': {
      'paragraphHash': 'a' * 64,
      'paragraphIndex': 0,
      'start': 3,
      'end': 6,
      'quote': 'ira'
    },
    'requestHash': 'b' * 64
  };
  test('PDF hints survive reopen and leave PDF bytes unchanged', () async {
    final original = await pdf.readAsBytes();
    final store = PdfHintStore();
    final snap = await store.read(pdf);
    await store.commit(
        snapshot: snap,
        pages: {
          'pdf:page:1': [record]
        },
        isCurrent: () => true);
    expect(
        (await PdfHintStore().read(pdf)).pages['pdf:page:1']!.first['spec']
            ['text'],
        'anger');
    expect(await pdf.readAsBytes(), original);
  });
  test(
      'stale concurrent snapshots and changed PDF cannot overwrite saved notes',
      () async {
    final store = PdfHintStore();
    final one = await store.read(pdf);
    final stale = await store.read(pdf);
    await store.commit(
        snapshot: one,
        pages: {
          'pdf:page:1': [record]
        },
        isCurrent: () => true);
    await expectLater(
        store.commit(snapshot: stale, pages: {}, isCurrent: () => true),
        throwsA(isA<Exception>()));
    expect((await store.read(pdf)).pages.length, 1);
    final snap = await store.read(pdf);
    await pdf.writeAsString('%PDF-1.7\nChanged');
    await expectLater(
        store.commit(snapshot: snap, pages: {}, isCurrent: () => true),
        throwsA(isA<Exception>()));
  });
  test('cancellation leaves no new sidecar and unsafe page keys are rejected',
      () async {
    final store = PdfHintStore();
    final snap = await store.read(pdf);
    await expectLater(
        store.commit(
            snapshot: snap,
            pages: {
              'pdf:page:1': [record]
            },
            isCurrent: () => false),
        throwsA(isA<Exception>()));
    expect(File('${pdf.path}.anx-hints.json').existsSync(), false);
    await expectLater(
        store.commit(
            snapshot: snap,
            pages: {
              '../../x': [record]
            },
            isCurrent: () => true),
        throwsA(isA<Exception>()));
  });
}
