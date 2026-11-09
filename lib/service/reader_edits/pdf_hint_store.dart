import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'epub_edit_store.dart';

class PdfHintSnapshot {
  const PdfHintSnapshot(
      this.file, this.sourceHash, this.sidecarHash, this.pages);
  final File file;
  final String sourceHash;
  final String? sidecarHash;
  final Map<String, List<Map<String, dynamic>>> pages;
}

/// Reader-owned sidecar: no model-supplied paths and no rewrite of PDF bytes.
class PdfHintStore {
  static final _locks = <String, Future<void>>{};
  static const _maxSidecarBytes = 16 * 1024 * 1024;
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

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  Future<void> _noLink(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const EpubEditException(
          'Unsafe PDF annotation path. Nothing was saved.');
    }
  }

  Map<String, List<Map<String, dynamic>>> _pages(Object? raw) {
    if (raw is! Map || raw.length > 10000)
      throw const FormatException('Invalid PDF annotation pages');
    var count = 0;
    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in raw.entries) {
      if (entry.key is! String ||
          !RegExp(r'^pdf:page:[1-9][0-9]{0,5}$').hasMatch(entry.key) ||
          entry.value is! List) {
        throw const FormatException('Invalid PDF annotation page');
      }
      final records = <Map<String, dynamic>>[];
      final ids = <String>{};
      for (final record in entry.value as List) {
        if (++count > 5000 ||
            record is! Map ||
            record['spec'] is! Map ||
            record['anchor'] is! Map ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch('${record['requestHash']}'))
          throw const FormatException('Invalid PDF annotation');
        final spec = record['spec'] as Map;
        if (!RegExp(r'^[A-Za-z0-9._-]{1,80}$')
                .hasMatch('${spec['operationId']}') ||
            !ids.add('${spec['operationId']}') ||
            !['ruby', 'footnote', 'highlight'].contains(spec['type']) ||
            spec['quote'] is! String ||
            (spec['quote'] as String).isEmpty ||
            (spec['quote'] as String).length > 500 ||
            spec['text'] is! String ||
            (spec['text'] as String).length > 1200)
          throw const FormatException('Invalid PDF annotation content');
        records.add(Map<String, dynamic>.from(record));
      }
      result[entry.key as String] = records;
    }
    return result;
  }

  Future<PdfHintSnapshot> read(File file) async {
    final path = await file.resolveSymbolicLinks();
    return _locked(path, () async {
      final source = File(path);
      final header = await source.open();
      try {
        if (!ascii
            .decode(await header.read(5), allowInvalid: true)
            .startsWith('%PDF-')) {
          throw const EpubEditException('The open file is not a PDF.');
        }
      } finally {
        await header.close();
      }
      final sourceHash = await _hash(source);
      final sidecar = File('$path.anx-hints.json');
      await _noLink(sidecar);
      if (!await sidecar.exists())
        return PdfHintSnapshot(source, sourceHash, null, {});
      if (await sidecar.length() > _maxSidecarBytes)
        throw const EpubEditException('PDF annotation data is too large.');
      final bytes = await sidecar.readAsBytes();
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map ||
          data['version'] != 1 ||
          data['sourceSha256'] != sourceHash) {
        throw const EpubEditException(
            'The PDF changed since its annotations were saved. Notes were preserved, but cannot be safely applied.');
      }
      return PdfHintSnapshot(source, sourceHash,
          sha256.convert(bytes).toString(), _pages(data['pages']));
    });
  }

  Future<void> commit(
          {required PdfHintSnapshot snapshot,
          required Map<String, dynamic> pages,
          required bool Function() isCurrent}) =>
      _locked(snapshot.file.path, () async {
        void check() {
          if (!isCurrent())
            throw const EpubEditException(
                'Book or account changed. Nothing was saved.');
        }

        check();
        final checked = _pages(pages);
        final sidecar = File('${snapshot.file.path}.anx-hints.json');
        final backup = File('${sidecar.path}.bak');
        await _noLink(sidecar);
        await _noLink(backup);
        final currentHash =
            await sidecar.exists() ? await _hash(sidecar) : null;
        if (currentHash != snapshot.sidecarHash ||
            await _hash(snapshot.file) != snapshot.sourceHash) {
          throw const EpubEditException(
              'PDF or annotations changed. Read the page again.');
        }
        final bytes = utf8.encode(jsonEncode({
          'version': 1,
          'sourceSha256': snapshot.sourceHash,
          'pages': checked
        }));
        if (bytes.length > _maxSidecarBytes)
          throw const EpubEditException('PDF annotation data is too large.');
        final nonce = List.generate(
            16,
            (_) => Random.secure()
                .nextInt(256)
                .toRadixString(16)
                .padLeft(2, '0')).join();
        final temp = File('${sidecar.path}.$nonce.tmp');
        try {
          await temp.writeAsBytes(bytes, flush: true);
          check();
          if (await sidecar.exists()) await sidecar.copy(backup.path);
          check();
          if (await _hash(snapshot.file) != snapshot.sourceHash) {
            throw const EpubEditException('PDF changed during save. Notes were not replaced.');
          }
          check();
          await temp.rename(sidecar.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      });
}
