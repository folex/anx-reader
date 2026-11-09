import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'book_image_assets.dart';
import 'book_image_filter.dart';
import 'epub_edit_store.dart';

Object? _canonicalImageRequest(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalImageRequest(value[key])};
  }
  if (value is List) return value.map(_canonicalImageRequest).toList();
  return value;
}

class ReaderBookImages {
  ReaderBookImages(
      {required this.file,
      required this.chapterHref,
      required this.vault,
      required this.current,
      required this.prepareInsertion,
      required this.save,
      required this.visibleIndices,
      required this.generate});
  final File file;
  final String chapterHref;
  final BookImageVault vault;
  final bool Function() current;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
      prepareInsertion;
  final Future<Map<String, dynamic>> Function(
      EpubChapterSnapshot, Map<String, dynamic>, List<EpubImageAsset>) save;
  final Future<List<int>> Function() visibleIndices;
  final Future<Uint8List> Function(String, Future<void> Function()) generate;
  void check() {
    if (!current())
      throw const EpubEditException(
          'The book, account, or request changed. Image operation canceled.');
  }

  Future<Map<String, dynamic>> handle(Map<String, dynamic> input) async {
    check();
    final action = input['action'];
    if (action == 'import' || action == 'generate') {
      final promptHash = action == 'generate'
          ? crypto.sha256
              .convert(utf8.encode(input['prompt'] as String))
              .toString()
          : '';
      final operationId = input['operationId'] as String?;
      if (action == 'generate') {
        if (operationId == null)
          throw const FormatException('Generation needs a stable operationId');
        final existing =
            await vault.existingGeneration(operationId, promptHash);
        if (existing != null)
          return {
            'imageId': existing,
            'readyToInsert': true,
            'origin': 'generated',
            'reused': true
          };
      }
      final Uint8List bytes = action == 'import'
          ? input['bytes'] as Uint8List
          : await generate(input['prompt'] as String, () async {
              check();
              await vault.startGeneration(operationId!, promptHash);
            });
      final png = await Isolate.run(() => processBookImage(bytes, {}));
      final id = await vault.put(png,
          origin: action == 'generate' ? 'generated' : 'imported');
      if (action == 'generate')
        await vault.finishGeneration(operationId!, promptHash, id);
      check();
      return {
        'imageId': id,
        'readyToInsert': true,
        'origin': action,
        'message':
            'Image is saved privately for this book. Use insert_book_image with an exact passage to embed it.'
      };
    }
    final store = EpubEditStore();
    final snapshot =
        await store.readChapter(file: file, chapterHref: chapterHref);
    check();
    final entries = bookImageEntries(snapshot);
    if (action == 'list') {
      final visible = await visibleIndices();
      check();
      final ordered = [
        ...entries.where((entry) => visible.contains(entry.index)),
        ...entries.where((entry) => !visible.contains(entry.index))
      ];
      return {
        'images': ordered
            .take(50)
            .map((entry) =>
                entry.describe(visible: visible.contains(entry.index)))
            .toList(),
        'pendingImages': await vault.recent(),
        'pendingOrder': 'most recent first',
        'total': entries.length,
        'truncated': entries.length > 50
      };
    }
    final requestHash = crypto.sha256
        .convert(utf8.encode(jsonEncode(_canonicalImageRequest(input))))
        .toString();
    if (action == 'insert') {
      final bytes = await vault.get(input['imageId'] as String);
      check();
      final asset = makeBookImageAsset(snapshot, bytes);
      final edit = await prepareInsertion(snapshot.xhtml, {
        ...input,
        'imageHref': bookImageHref(snapshot, asset),
        'requestHash': requestHash
      });
      check();
      return save(snapshot, edit, [asset]);
    }
    if (action != 'edit')
      throw const FormatException('Unknown image operation');
    final op = input['operationId'] as String;
    for (final entry in entries) {
      if (entry.element.getAttribute('data-anx-image-operation-id') != op)
        continue;
      if (entry.element.getAttribute('data-anx-image-request-hash') !=
          requestHash)
        throw const EpubEditException(
            'Image operationId was already used with different arguments.');
      return {'changed': false, 'operationId': op};
    }
    final matches = entries.where((entry) => entry.id == input['imageId']);
    if (matches.length != 1)
      throw const EpubEditException(
          'Image ID is stale or unavailable. Call get_book_images again.');
    final entry = matches.single;
    if (entry.describe()['localEditing'] != true)
      throw const EpubEditException(
          'Local editing currently supports embedded still raster images, without picture/srcset markup. The original image was preserved.');
    final image = entry.element;
    final assets = <EpubImageAsset>[];
    final restoring = input['restore'] == true;
    if (restoring) {
      image.setAttribute('src', entry.originalHref);
      image.removeAttribute('data-anx-image-base-src');
      image.removeAttribute('data-anx-image-dark-src');
    } else {
      final bytes =
          await store.readImage(snapshot: snapshot, href: entry.originalHref);
      final filters = Map<String, dynamic>.from(input['filters'] as Map? ?? {});
      final transformed =
          await Isolate.run(() => processBookImage(bytes, filters));
      check();
      final asset = makeBookImageAsset(snapshot, transformed);
      assets.add(asset);
      final href = bookImageHref(snapshot, asset);
      if (input['target'] == 'dark') {
        image.setAttribute('data-anx-image-dark-src', href);
      } else {
        image.setAttribute('data-anx-image-base-src', href);
        image.removeAttribute('data-anx-image-dark-src');
        image.setAttribute('src', href);
      }
    }
    image.setAttribute('data-anx-image-original-src', entry.originalHref);
    image.setAttribute('data-anx-image-operation-id', op);
    image.setAttribute('data-anx-image-request-hash', requestHash);
    check();
    return save(
        snapshot,
        {
          'xhtml': entry.document.toXmlString(),
          'unchanged': false,
          'operationId': op
        },
        assets);
  }
}
