import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as native show ZLibDecoder;
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

class EpubEditException implements Exception {
  const EpubEditException(this.message);
  final String message;
  @override
  String toString() => message;
}

class EpubChapterSnapshot {
  EpubChapterSnapshot._(
    this.file,
    this.chapterPath,
    this.xhtml,
    this.sha256,
    this.bookIdentifier,
    this.packagePath,
  );
  final File file;
  final String chapterPath, xhtml, sha256, bookIdentifier, packagePath;
}

class EpubImageAsset {
  const EpubImageAsset({required this.path, required this.bytes});
  final String path;
  final Uint8List bytes;
}

class EpubEditResult {
  const EpubEditResult({required this.changed, this.backupPath});
  final bool changed;
  final String? backupPath;
}

/// Trusted application code supplies File. Model input never supplies a path.
class EpubEditStore {
  static const maxArchiveBytes = 128 * 1024 * 1024,
      maxChapterBytes = 4 * 1024 * 1024;
  static final Map<String, Future<void>> _locks = {};
  Future<T> _locked<T>(String path, Future<T> Function() action) async {
    final previous = _locks[path] ?? Future<void>.value();
    final gate = Completer<void>();
    final tail = previous.then((_) => gate.future);
    _locks[path] = tail;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(_locks[path], tail)) _locks.remove(path);
    }
  }

  Future<EpubChapterSnapshot> readChapter({
    required File file,
    required String chapterHref,
  }) async {
    final path = await file.resolveSymbolicLinks();
    return _locked(path, () async {
      final original = File(path);
      final digest = await _hash(original);
      final opened = _Opened(original);
      try {
        final requested = _safePath(
          Uri.decodeComponent(Uri.parse(chapterHref).path),
        );
        final package = opened.packageDocument();
        final chapter = opened.headers.containsKey(requested)
            ? requested
            : opened.resolveHref(requested);
        if (!opened.headers.containsKey(chapter))
          throw const EpubEditException('Chapter not found in EPUB.');
        final xhtml = opened.text(chapter, maxChapterBytes);
        _chapter(xhtml);
        final item = opened.items
            .where((x) => opened.isChapterItem(x, chapter))
            .firstOrNull;
        if (item == null ||
            item.getAttribute('media-type') != 'application/xhtml+xml')
          throw const EpubEditException('Selected EPUB chapter is not XHTML.');
        if (!package.descendants.whereType<XmlElement>().any(
              (e) =>
                  e.name.local == 'itemref' &&
                  e.getAttribute('idref') == item.getAttribute('id'),
            )) {
          throw const EpubEditException(
            'Selected document is not in the EPUB reading order.',
          );
        }
        if (await _hash(original) != digest)
          throw const EpubEditException(
            'The book changed while reading. Try again.',
          );
        return EpubChapterSnapshot._(
          original,
          chapter,
          xhtml,
          digest,
          opened.identifier,
          opened.opfPath,
        );
      } finally {
        opened.close();
      }
    });
  }

  Future<Uint8List> readImage(
          {required EpubChapterSnapshot snapshot, required String href}) =>
      _locked(snapshot.file.path, () async {
        if (await _hash(snapshot.file) != snapshot.sha256)
          throw const EpubEditException('EPUB changed. List the images again.');
        final opened = _Opened(snapshot.file);
        try {
          opened.packageDocument();
          final uri = Uri.tryParse(href);
          if (uri == null ||
              uri.hasScheme ||
              uri.hasAuthority ||
              uri.hasQuery ||
              uri.hasFragment)
            throw const EpubEditException(
                'Only embedded EPUB images can be edited.');
          final path = _safePath(p.posix.normalize(p.posix.join(
              p.posix.dirname(snapshot.chapterPath),
              Uri.decodeComponent(uri.path))));
          final item = opened.items.where((item) {
            if (!(item.getAttribute('media-type') ?? '').startsWith('image/'))
              return false;
            final href = Uri.tryParse(item.getAttribute('href') ?? '');
            if (href == null ||
                href.hasScheme ||
                href.hasAuthority ||
                href.hasQuery ||
                href.hasFragment) return false;
            return opened.resolveHref(href.toString()) == path;
          }).firstOrNull;
          if (item == null)
            throw const EpubEditException(
                'Embedded image is not registered in the EPUB manifest.');
          return opened.bytes(path, 12 * 1024 * 1024);
        } finally {
          opened.close();
        }
      });

  Future<EpubEditResult> commit({
    required EpubChapterSnapshot snapshot,
    required String xhtml,
    required bool Function() isCurrent,
    List<EpubImageAsset> images = const [],
  }) =>
      _locked(snapshot.file.path, () async {
        void check() {
          if (!isCurrent())
            throw const EpubEditException(
              'The book or chat changed. Changes canceled.',
            );
        }

        check();
        final doc = _chapter(xhtml);
        final originalDoc = _chapter(snapshot.xhtml);
        if (_visibleText(doc) != _visibleText(originalDoc))
          throw const EpubEditException(
            'Original chapter text changed; save canceled.',
          );
        if (xhtml == snapshot.xhtml && images.isEmpty)
          return const EpubEditResult(changed: false);
        if (await _hash(snapshot.file) != snapshot.sha256)
          throw const EpubEditException(
            'EPUB has changed. Read the chapter again.',
          );
        check();
        final opened = _Opened(snapshot.file);
        final nonce = List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final temp = File('${snapshot.file.path}.anx-$nonce.tmp');
        final backup = File('${snapshot.file.path}.anx-edit.bak');
        final backupTemp = File('${backup.path}.$nonce.tmp');
        try {
          final package = opened.packageDocument();
          final replacements = <String, List<int>>{
            snapshot.chapterPath: utf8.encode(xhtml),
          };
          if (images.length > 4)
            throw const EpubEditException(
                'Too many image assets in one commit.');
          for (final image in images) {
            final digest = crypto.sha256.convert(image.bytes).toString();
            final expected = p.posix.join(
                p.posix.dirname(opened.opfPath), 'anx-images', '$digest.png');
            if (_safePath(image.path) != expected ||
                image.bytes.length < 8 ||
                image.bytes.length > 12 * 1024 * 1024 ||
                !List.generate(
                    8,
                    (i) =>
                        image.bytes[i] ==
                        [137, 80, 78, 71, 13, 10, 26, 10][i]).every((x) => x)) {
              throw const EpubEditException('Invalid PNG image asset.');
            }
            if (opened.headers.containsKey(image.path) &&
                crypto.sha256
                        .convert(opened.bytes(image.path, 12 * 1024 * 1024))
                        .toString() !=
                    digest) {
              throw const EpubEditException(
                  'Image asset collision. Nothing was saved.');
            }
            replacements[image.path] = image.bytes;
            final href = p.posix
                .relative(image.path, from: p.posix.dirname(opened.opfPath));
            final existing = opened.items
                .where((item) => item.getAttribute('href') == href)
                .firstOrNull;
            if (existing != null &&
                existing.getAttribute('media-type') != 'image/png')
              throw const EpubEditException('Image manifest collision.');
            if (existing == null) {
              final id = 'anx-image-$digest';
              if (opened.items.any((item) => item.getAttribute('id') == id))
                throw const EpubEditException('Image manifest ID collision.');
              final added =
                  XmlElement(XmlName('item', opened.manifest.name.prefix), [
                XmlAttribute(XmlName('id'), id),
                XmlAttribute(XmlName('href'), href),
                XmlAttribute(XmlName('media-type'), 'image/png'),
              ]);
              opened.manifest.children.add(added);
              opened.items.add(added);
            }
          }
          final item = opened.items.firstWhere(
            (x) => opened.isChapterItem(x, snapshot.chapterPath),
          );
          if (doc.descendants.whereType<XmlElement>().any(
                (e) => e.name.local == 'script',
              )) {
            final properties = (item.getAttribute('properties') ?? '')
                .split(RegExp(r'\s+'))
                .where((x) => x.isNotEmpty)
                .toSet()
              ..add('scripted');
            item.setAttribute('properties', properties.join(' '));
          }
          if (package.rootElement.getAttribute('version') != '3.0') {
            package.rootElement.setAttribute('version', '3.0');
            if (!opened.items.any(
              (x) => (x.getAttribute('properties') ?? '')
                  .split(' ')
                  .contains('nav'),
            )) {
              var name = 'anx-edit-nav.xhtml';
              var n = 1;
              while (opened.headers.containsKey(opened.resolveHref(name))) {
                name = 'anx-edit-nav-${n++}.xhtml';
              }
              var id = 'anx-edit-nav';
              n = 1;
              final ids = opened.items.map((x) => x.getAttribute('id')).toSet();
              while (ids.contains(id)) {
                id = 'anx-edit-nav-${n++}';
              }
              final manifest = opened.manifest;
              manifest.children.add(
                XmlElement(XmlName('item', manifest.name.prefix), [
                  XmlAttribute(XmlName('id'), id),
                  XmlAttribute(XmlName('href'), name),
                  XmlAttribute(XmlName('media-type'), 'application/xhtml+xml'),
                  XmlAttribute(XmlName('properties'), 'nav'),
                ]),
              );
              final links = <String>[];
              for (final ref
                  in package.descendants.whereType<XmlElement>().where(
                        (e) => e.name.local == 'itemref',
                      )) {
                final found = opened.items
                    .where((i) =>
                        i.getAttribute('id') == ref.getAttribute('idref'))
                    .firstOrNull;
                if (found != null) links.add(found.getAttribute('href')!);
              }
              final nav = XmlBuilder()
                ..processing('xml', 'version="1.0" encoding="UTF-8"');
              nav.element(
                'html',
                namespaces: {
                  'http://www.w3.org/1999/xhtml': '',
                  'http://www.idpf.org/2007/ops': 'epub',
                },
                nest: () {
                  nav.element(
                    'head',
                    nest: () => nav.element('title', nest: 'Contents'),
                  );
                  nav.element(
                    'body',
                    nest: () => nav.element(
                      'nav',
                      attributes: {'epub:type': 'toc', 'id': 'toc'},
                      nest: () => nav.element(
                        'ol',
                        nest: () {
                          for (var i = 0; i < links.length; i++) {
                            nav.element(
                              'li',
                              nest: () => nav.element(
                                'a',
                                attributes: {'href': links[i]},
                                nest: '${i + 1}',
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  );
                },
              );
              replacements[opened.resolveHref(name)] = utf8.encode(
                nav.buildDocument().toXmlString(),
              );
            }
          }
          final metadata =
              package.descendants.whereType<XmlElement>().firstWhere(
                    (e) => e.name.local == 'metadata',
                  );
          final modified = metadata.childElements
              .where(
                (e) =>
                    e.name.local == 'meta' &&
                    e.getAttribute('property') == 'dcterms:modified',
              )
              .toList();
          final timestamp =
              DateTime.now().toUtc().toIso8601String().substring(0, 19) + 'Z';
          for (final entry in modified) {
            entry.parent?.children.remove(entry);
          }
          metadata.children.add(
            XmlElement(
              XmlName('meta', metadata.name.prefix),
              [XmlAttribute(XmlName('property'), 'dcterms:modified')],
              [XmlText(timestamp)],
            ),
          );
          replacements[opened.opfPath] = utf8.encode(package.toXmlString());
          check();
          final output = OutputFileStream(temp.path);
          var encoded = false;
          try {
            final encoder = ZipEncoder()..startEncode(output);
            final mime = ArchiveFile(
              'mimetype',
              20,
              utf8.encode('application/epub+zip'),
            )..compress = false;
            encoder.addFile(mime, autoClose: false);
            for (final file in opened.archive.files) {
              if (file.name == 'mimetype') continue;
              final replacement = replacements.remove(file.name);
              if (replacement != null) {
                encoder.addFile(
                  ArchiveFile(file.name, replacement.length, replacement),
                  autoClose: false,
                );
              } else {
                file.rawContent?.reset();
                if (file.compressionType == ArchiveFile.STORE &&
                    file.rawContent != null) {
                  final stored =
                      ArchiveFile.stream(file.name, file.size, file.rawContent!)
                        ..compress = false
                        ..crc32 = file.crc32
                        ..mode = file.mode
                        ..isFile = file.isFile
                        ..lastModTime = file.lastModTime
                        ..comment = file.comment;
                  encoder.addFile(stored, autoClose: false);
                } else {
                  encoder.addFile(file, autoClose: false);
                }
              }
            }
            for (final entry in replacements.entries) {
              encoder.addFile(
                ArchiveFile(entry.key, entry.value.length, entry.value),
                autoClose: false,
              );
            }
            encoder.endEncode();
            encoded = true;
          } finally {
            if (encoded) {
              output.closeSync();
            } else {
              _bestEffort(output.closeSync);
            }
          }
          _flushFile(temp);
          if (temp.lengthSync() > maxArchiveBytes)
            throw const EpubEditException(
              'Updated EPUB exceeds the size limit.',
            );
          // Keep a single previous complete archive; never delete the live book.
          if (await _hash(snapshot.file) != snapshot.sha256)
            throw const EpubEditException(
              'EPUB changed during preparation. Try again.',
            );
          check();
          if (FileSystemEntity.typeSync(backup.path, followLinks: false) ==
              FileSystemEntityType.link)
            throw const EpubEditException('Unsafe backup path.');
          snapshot.file.copySync(backupTemp.path);
          if (await _hash(backupTemp) != snapshot.sha256 ||
              await _hash(snapshot.file) != snapshot.sha256) {
            throw const EpubEditException(
              'EPUB changed during backup. Save canceled.',
            );
          }
          _flushFile(backupTemp);
          check();
          backupTemp.renameSync(backup.path);
          check();
          temp.renameSync(snapshot.file.path);
          return EpubEditResult(changed: true, backupPath: backup.path);
        } finally {
          opened.close();
          _bestEffort(() {
            if (temp.existsSync()) temp.deleteSync();
          });
          _bestEffort(() {
            if (backupTemp.existsSync()) backupTemp.deleteSync();
          });
        }
      });
  Future<String> _hash(File file) async {
    final length = await file.length();
    if (length <= 0 || length > maxArchiveBytes)
      throw const EpubEditException('EPUB size is outside the allowed range.');
    return (await crypto.sha256.bind(file.openRead()).first).toString();
  }
}

String _safePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.split('/').any((part) => part == '..' || part == '.') ||
      path.contains('\u0000'))
    throw const EpubEditException('Invalid path inside EPUB.');
  final normalized = p.posix.normalize(path);
  if (normalized != path || normalized == '.' || normalized.startsWith('../'))
    throw const EpubEditException('Invalid EPUB path.');
  return normalized;
}

XmlDocument _xml(String text) {
  final withoutBasicDoctype = text.replaceAll(
    RegExp(r'<!DOCTYPE\s+html\s*>', caseSensitive: false),
    '',
  );
  if (RegExp(
    r'<!DOCTYPE|<!ENTITY',
    caseSensitive: false,
  ).hasMatch(withoutBasicDoctype))
    throw const EpubEditException(
        'DTD and external entities are not supported.');
  try {
    return XmlDocument.parse(text);
  } catch (_) {
    throw const EpubEditException('Invalid XML/XHTML.');
  }
}

XmlDocument _chapter(String text) {
  if (utf8.encode(text).length > EpubEditStore.maxChapterBytes)
    throw const EpubEditException('Chapter is too large.');
  final doc = _xml(text);
  if (doc.rootElement.name.local != 'html' ||
      !doc.descendants.whereType<XmlElement>().any(
            (e) => e.name.local == 'body',
          )) throw const EpubEditException('Expected an XHTML chapter.');
  return doc;
}

String _visibleText(XmlDocument doc) {
  final body = doc.descendants.whereType<XmlElement>().firstWhere(
        (e) => e.name.local == 'body',
      );
  final out = StringBuffer();
  void visit(XmlNode node) {
    if (node is XmlElement) {
      if ({'rt', 'script', 'style'}.contains(node.name.local) ||
          node.getAttribute('data-anx-edit-added') != null) return;
    }
    if (node is XmlText)
      out.write(node.value);
    else if (node is XmlCDATA)
      out.write(node.value);
    else {
      for (final child in node.children) visit(child);
    }
  }

  visit(body);
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.maximum);
  final int maximum;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int length = 0;
  @override
  void add(List<int> data) {
    length += data.length;
    if (length > maximum)
      throw const EpubEditException('XML exceeds the size limit.');
    bytes.add(data);
  }

  @override
  void close() {}
}

class _Opened {
  _Opened(File file) : input = InputFileStream(file.path) {
    try {
      final directory = ZipDirectory.read(input);
      if (directory.fileHeaders.length > 10000 ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0)
        throw const EpubEditException(
          'Complex or multi-volume ZIP is not supported.',
        );
      var total = 0;
      for (final h in directory.fileHeaders) {
        final name = _safePath(
          h.filename.endsWith('/')
              ? h.filename.substring(0, h.filename.length - 1)
              : h.filename,
        );
        if (h.file!.filename != h.filename ||
            h.file!.flags & 1 != 0 ||
            h.file!.compressionMethod != h.compressionMethod ||
            headers.containsKey(name) ||
            (h.externalFileAttributes! >> 16) & 0xf000 == 0xa000 ||
            h.generalPurposeBitFlag & 1 != 0 ||
            !{0, 8}.contains(h.compressionMethod))
          throw const EpubEditException(
            'EPUB contains an unsafe ZIP entry.',
          );
        if (h.uncompressedSize! < 0 ||
            h.compressedSize! < 0 ||
            h.compressedSize! > EpubEditStore.maxArchiveBytes ||
            h.uncompressedSize! > 512 * 1024 * 1024)
          throw const EpubEditException('ZIP entry is too large.');
        total += h.uncompressedSize!;
        if (total > 1024 * 1024 * 1024)
          throw const EpubEditException(
            'Total ZIP size is too large.',
          );
        headers[name] = h;
      }
      input.reset();
      archive = ZipDecoder().decodeBuffer(input, verify: false);
    } catch (_) {
      _bestEffort(input.closeSync);
      rethrow;
    }
  }
  final InputFileStream input;
  final Map<String, ZipFileHeader> headers = {};
  late final Archive archive;
  late String opfPath, identifier;
  late XmlElement manifest;
  late List<XmlElement> items;
  String text(String name, int maximum) => utf8.decode(bytes(name, maximum));

  Uint8List bytes(String name, int maximum) {
    final h = headers[name];
    if (h == null || h.uncompressedSize! > maximum)
      throw const EpubEditException(
        'EPUB XML is missing or too large.',
      );
    final raw = h.file!.rawContent!;
    raw.reset();
    final sink = _BoundedSink(maximum);
    try {
      if (h.compressionMethod == 0) {
        while (!raw.isEOS) {
          sink.add(raw.readBytes(min(32768, raw.length)).toUint8List());
        }
      } else {
        final decoder = native.ZLibDecoder(
          raw: true,
        ).startChunkedConversion(sink);
        while (!raw.isEOS) {
          decoder.add(raw.readBytes(min(32768, raw.length)).toUint8List());
        }
        decoder.close();
      }
      final bytes = sink.bytes.takeBytes();
      if (bytes.length != h.uncompressedSize || getCrc32(bytes) != h.crc32)
        throw const EpubEditException('Invalid XML inside EPUB.');
      return bytes;
    } finally {
      raw.reset();
    }
  }

  XmlDocument packageDocument() {
    final container = _xml(text('META-INF/container.xml', 256 * 1024));
    final rootfile = container.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'rootfile')
        .firstOrNull;
    if (rootfile == null)
      throw const EpubEditException('EPUB package document is missing.');
    opfPath = _safePath(rootfile.getAttribute('full-path') ?? '');
    final doc = _xml(text(opfPath, 1024 * 1024));
    manifest = doc.descendants.whereType<XmlElement>().firstWhere(
          (e) => e.name.local == 'manifest',
        );
    items =
        manifest.childElements.where((e) => e.name.local == 'item').toList();
    final uid = doc.rootElement.getAttribute('unique-identifier');
    identifier = doc.descendants
            .whereType<XmlElement>()
            .where(
              (e) =>
                  e.name.local == 'identifier' && e.getAttribute('id') == uid,
            )
            .firstOrNull
            ?.innerText ??
        '';
    return doc;
  }

  bool isChapterItem(XmlElement item, String path) {
    if (item.getAttribute('media-type') != 'application/xhtml+xml')
      return false;
    final href = item.getAttribute('href') ?? '';
    final uri = Uri.tryParse(href);
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment) return false;
    return resolveHref(href) == path;
  }

  String resolveHref(String href) {
    final uri = Uri.parse(href);
    if (uri.hasScheme || uri.hasAuthority || uri.hasQuery || uri.hasFragment)
      throw const EpubEditException(
          'External EPUB resources are not supported.');
    return _safePath(
      p.posix.normalize(
        p.posix.join(p.posix.dirname(opfPath), Uri.decodeComponent(uri.path)),
      ),
    );
  }

  void close() => _bestEffort(input.closeSync);
}

// Durability failures occur before replacing the live EPUB. Closing after an
// fsync failure and all final cleanup must never mask the primary result/error.
void _flushFile(File file) {
  final handle = file.openSync(mode: FileMode.append);
  try {
    handle.flushSync();
  } catch (_) {
    _bestEffort(handle.closeSync);
    rethrow;
  }
  handle.closeSync();
}

void _bestEffort(void Function() action) {
  try {
    action();
  } catch (_) {
    /* preserve the commit result or primary error */
  }
}
