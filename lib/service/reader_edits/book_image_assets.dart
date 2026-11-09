import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'epub_edit_store.dart';

class BookImageEntry {
  const BookImageEntry(
      {required this.id,
      required this.index,
      required this.originalHref,
      required this.element,
      required this.document});
  final String id, originalHref;
  final int index;
  final XmlElement element;
  final XmlDocument document;
  Map<String, dynamic> describe({bool visible = false}) => {
        'imageId': id,
        'index': index,
        'visible': visible,
        'alt': (element.getAttribute('alt') ?? '').substring(
            0, (element.getAttribute('alt') ?? '').length.clamp(0, 300)),
        'filename': path.posix
            .basename(Uri.tryParse(originalHref)?.path ?? '')
            .substring(
                0,
                path.posix
                    .basename(Uri.tryParse(originalHref)?.path ?? '')
                    .length
                    .clamp(0, 120)),
        'hasDarkVariant':
            element.getAttribute('data-anx-image-dark-src') != null,
        'hasEditedVersion':
            element.getAttribute('data-anx-image-base-src') != null,
        'localEditing': !originalHref.contains(':') &&
            !originalHref.startsWith('//') &&
            !originalHref.toLowerCase().endsWith('.svg') &&
            element.getAttribute('srcset') == null &&
            (element.parent is! XmlElement ||
                (element.parent as XmlElement).name.local != 'picture'),
      };
}

List<BookImageEntry> bookImageEntries(EpubChapterSnapshot snapshot) {
  final doc = XmlDocument.parse(snapshot.xhtml);
  final elements = doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == 'img')
      .toList();
  return [
    for (var index = 0; index < elements.length; index++)
      BookImageEntry(
        id: crypto.sha256
            .convert(utf8.encode(
                '${snapshot.sha256}\n${snapshot.chapterPath}\n$index\n${elements[index].getAttribute('data-anx-image-original-src') ?? elements[index].getAttribute('src') ?? ''}'))
            .toString(),
        index: index,
        element: elements[index],
        document: doc,
        originalHref:
            elements[index].getAttribute('data-anx-image-original-src') ??
                elements[index].getAttribute('src') ??
                '',
      ),
  ];
}

EpubImageAsset makeBookImageAsset(
        EpubChapterSnapshot snapshot, Uint8List bytes) =>
    EpubImageAsset(
      path: path.posix.join(path.posix.dirname(snapshot.packagePath),
          'anx-images', '${crypto.sha256.convert(bytes)}.png'),
      bytes: bytes,
    );

String bookImageHref(EpubChapterSnapshot snapshot, EpubImageAsset image) => Uri(
        path: path.posix.relative(image.path,
            from: path.posix.dirname(snapshot.chapterPath)))
    .toString();

/// Imported/generated images are private app files, bound to this book/account.
/// Tool arguments contain only a content ID, never a device path or raw bytes.
class BookImageVault {
  BookImageVault(this.scope, {this.root});
  final String scope;
  final Directory? root;
  Future<Directory> _directory() async {
    final parent = root ?? await getApplicationSupportDirectory();
    return Directory(path.join(parent.path, 'reader-images',
            crypto.sha256.convert(utf8.encode(scope)).toString()))
        .create(recursive: true);
  }

  Future<String> put(Uint8List bytes, {String origin = 'imported'}) async {
    final id = 'image_${crypto.sha256.convert(bytes)}';
    final directory = await _directory();
    final file = File(path.join(directory.path, '$id.png'));
    if (!await file.exists()) {
      final temp =
          File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      try {
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
    await file.setLastModified(DateTime.now());
    await File(path.join(directory.path, '$id.json'))
        .writeAsString(jsonEncode({'origin': origin}), flush: true);
    return id;
  }

  Future<List<Map<String, dynamic>>> recent() async {
    final directory = await _directory();
    final files = <(File, DateTime)>[];
    await for (final entity in directory.list()) {
      if (entity is File &&
          RegExp(r'^image_[a-f0-9]{64}\.png$')
              .hasMatch(path.basename(entity.path))) {
        files.add((entity, (await entity.stat()).modified));
      }
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    final result = <Map<String, dynamic>>[];
    for (final (file, _) in files.take(8)) {
      final id = path.basenameWithoutExtension(file.path);
      String origin = 'ready';
      try {
        final data = jsonDecode(
            await File(path.join(directory.path, '$id.json')).readAsString());
        if (data is Map && ['imported', 'generated'].contains(data['origin']))
          origin = data['origin'];
      } catch (_) {}
      result.add({'imageId': id, 'origin': origin, 'readyToInsert': true});
    }
    return result;
  }

  Future<File> _generationFile(String operationId) async {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(operationId))
      throw const FormatException('Invalid generation operationId');
    final directory = await _directory();
    return File(path.join(directory.path,
        'generation-${crypto.sha256.convert(utf8.encode(operationId))}.json'));
  }

  Future<String?> existingGeneration(
      String operationId, String requestHash) async {
    final file = await _generationFile(operationId);
    if (!await file.exists()) return null;
    if (await file.length() > 4096)
      throw const EpubEditException('Invalid saved image generation record.');
    final data = jsonDecode(await file.readAsString());
    if (data is! Map || data['requestHash'] != requestHash)
      throw const EpubEditException(
          'Generation operationId was already used with different arguments.');
    if (data['status'] == 'ready' && data['imageId'] is String) {
      await get(data['imageId']);
      return data['imageId'] as String;
    }
    throw const EpubEditException(
        'This image generation was already requested but has no confirmed result. Check Image API usage before explicitly requesting a new generation. It was not sent again.');
  }

  Future<void> startGeneration(String operationId, String requestHash) async {
    final file = await _generationFile(operationId);
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      throw const EpubEditException(
          'This image generation has already started. It was not sent again.');
    }
    await file.writeAsString(
        jsonEncode({'requestHash': requestHash, 'status': 'started'}),
        flush: true);
  }

  Future<void> finishGeneration(
      String operationId, String requestHash, String imageId) async {
    final file = await _generationFile(operationId);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
          jsonEncode({
            'requestHash': requestHash,
            'status': 'ready',
            'imageId': imageId
          }),
          flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Uint8List> get(String id) async {
    if (!RegExp(r'^image_[a-f0-9]{64}$').hasMatch(id))
      throw const EpubEditException('Unknown imported/generated image ID.');
    final directory = await _directory();
    final file = File(path.join(directory.path, '$id.png'));
    if (!await file.exists() || await file.length() > 12 * 1024 * 1024)
      throw const EpubEditException(
          'Image is unavailable for this book and account. Import or generate it again.');
    final bytes = await file.readAsBytes();
    if ('image_${crypto.sha256.convert(bytes)}' != id)
      throw const EpubEditException('Image failed its integrity check.');
    return bytes;
  }
}
