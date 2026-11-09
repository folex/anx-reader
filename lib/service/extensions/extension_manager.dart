import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'extension_package.dart';

class ExtensionManager extends ChangeNotifier {
  static final instance = ExtensionManager();
  final Map<String, ReaderExtension> installed = {};
  final Map<String, Set<String>> grants = {};
  int revision = 0;
  Future<void>? _loading;
  Directory? _directory;
  Future<void> initialize() => _loading ??= _load();
  Future<void> _load() async {
    _directory = Directory(
        '${(await getApplicationSupportDirectory()).path}/extensions-v1');
    await _directory!.create(recursive: true);
    final state = File('${_directory!.path}/grants.json');
    final saved =
        state.existsSync() ? jsonDecode(await state.readAsString()) as Map : {};
    for (final file in _directory!.listSync().whereType<File>()) {
      if (!file.path.endsWith('.anxplugin')) continue;
      try {
        final extension = ReaderExtension.decode(await file.readAsBytes());
        installed[extension.id] = extension;
        grants[extension.id] =
            Set<String>.from(saved[extension.id] as List? ?? [])
                .intersection(extension.permissions.toSet());
      } catch (_) {/* A broken package must not prevent the reader starting. */}
    }
  }

  Future<void> install(List<int> bytes, Set<String> approved) async {
    final extension = ReaderExtension.decode(bytes);
    if (!approved.every(extension.permissions.contains)) {
      throw StateError('Invalid grants');
    }
    await initialize();
    final target = File('${_directory!.path}/${extension.id}.anxplugin');
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
    installed[extension.id] = extension;
    grants[extension.id] = approved.toSet();
    await _save();
  }

  Future<void> setPermission(String id, String permission, bool value) async {
    final extension = installed[id]!;
    if (!extension.permissions.contains(permission)) {
      throw StateError('Undeclared permission');
    }
    final allowed = grants.putIfAbsent(id, () => {});
    value ? allowed.add(permission) : allowed.remove(permission);
    await _save();
  }

  Future<void> _stateWrites = Future.value();
  Future<void> _save() {
    final body = jsonEncode(grants.map((k, v) => MapEntry(k, v.toList())));
    revision++;
    notifyListeners();
    final write = _stateWrites.catchError((_) {}).then((_) async {
      final target = File('${_directory!.path}/grants.json');
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(body, flush: true);
      await temporary.rename(target.path);
    });
    _stateWrites = write;
    return write;
  }

  Future<void> _storageWrites = Future.value();
  Future<Object?> readValue(String id, String key) async {
    await _storageWrites.catchError((_) {});
    final file = _storageFile(id, key);
    return file.existsSync() ? jsonDecode(await file.readAsString()) : null;
  }

  Future<void> writeValue(String id, String key, Object? value) {
    final body = jsonEncode(value);
    if (utf8.encode(body).length > 128 * 1024) {
      throw StateError('Extension value exceeds 128 KB');
    }
    final file = _storageFile(id, key);
    final write = _storageWrites.catchError((_) {}).then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(body, flush: true);
      await temporary.rename(file.path);
    });
    _storageWrites = write;
    return write;
  }

  Future<Object?> claimValue(String id, String key, Object? value) {
    final body = jsonEncode(value);
    if (utf8.encode(body).length > 128 * 1024) {
      throw StateError('Extension value exceeds 128 KB');
    }
    final file = _storageFile(id, key);
    final operation =
        _storageWrites.catchError((_) {}).then<Object?>((_) async {
      if (file.existsSync()) return jsonDecode(await file.readAsString());
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(body, flush: true);
      await temporary.rename(file.path);
      return null;
    });
    _storageWrites =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  File _storageFile(String id, String key) {
    if (!installed.containsKey(id) ||
        !RegExp(r'^[a-zA-Z0-9._-]{1,100}$').hasMatch(key)) {
      throw StateError('Invalid extension storage key');
    }
    return File('${_directory!.path}/state/$id/$key.json');
  }

  List<String> get toolIds => installed.values
      .expand((extension) =>
          extension.tools.map((tool) => extension.toolId(tool['name'])))
      .toList();
}
