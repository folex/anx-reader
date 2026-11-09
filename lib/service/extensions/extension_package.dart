import 'dart:convert';
import 'package:archive/archive.dart';

const extensionPermissions = {'books.read', 'books.write', 'ui', 'network'};

class ReaderExtension {
  ReaderExtension(this.manifest, this.script);
  final Map<String, dynamic> manifest;
  final String script;
  String get id => manifest['id'] as String;
  String get name => manifest['name'] as String;
  String get version => manifest['version'] as String;
  List<String> get permissions => List<String>.from(manifest['permissions']);
  List<String> get origins => List<String>.from(manifest['origins']);
  List<Map<String, dynamic>> get tools => (manifest['tools'] as List)
      .map((item) => Map<String, dynamic>.from(item as Map)).toList();
  String toolId(String name) => 'ext_${id.replaceAll('-', '_')}_$name';

  factory ReaderExtension.decode(List<int> bytes) {
    if (bytes.length > 1024 * 1024) throw const FormatException('Extension exceeds 1 MB');
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final entries = <String, ArchiveFile>{};
    var size = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (!{'manifest.json', 'plugin.js', 'LICENSE', 'README.md'}.contains(entry.name) ||
          entries.containsKey(entry.name)) {
        throw const FormatException('Unexpected or duplicate extension file');
      }
      size += entry.size;
      if (size > 1024 * 1024) throw const FormatException('Expanded extension exceeds 1 MB');
      entries[entry.name] = entry;
    }
    if (!entries.containsKey('manifest.json') || !entries.containsKey('plugin.js')) {
      throw const FormatException('manifest.json and plugin.js are required');
    }
    final raw = jsonDecode(utf8.decode(entries['manifest.json']!.content as List<int>));
    if (raw is! Map<String, dynamic>) throw const FormatException('Invalid manifest');
    final id = raw['id'];
    if (raw['apiVersion'] != 1 || id is! String ||
        !RegExp(r'^[a-z][a-z0-9-]{0,23}$').hasMatch(id) ||
        raw['name'] is! String || (raw['name'] as String).length > 100 ||
        raw['version'] is! String || (raw['version'] as String).length > 40) {
      throw const FormatException('Unsupported extension identity or API version');
    }
    final permissions = raw['permissions'];
    if (permissions is! List || permissions.any((p) => !extensionPermissions.contains(p))) {
      throw const FormatException('Unknown permission');
    }
    final origins = raw['origins'];
    if (origins is! List || origins.length > 20 || origins.any((value) {
      if (value is! String) return true;
      final uri = Uri.tryParse(value);
      return uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
          uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/') || uri.origin != value;
    })) throw const FormatException('Origins must be exact HTTPS origins');
    final tools = raw['tools'];
    if (tools is! List || tools.isEmpty || tools.length > 20) {
      throw const FormatException('Expected 1-20 tools');
    }
    final names = <String>{};
    for (final tool in tools) {
      if (tool is! Map || tool['name'] is! String ||
          !RegExp(r'^[a-z][a-z0-9_]{0,30}$').hasMatch(tool['name']) ||
          !names.add(tool['name']) || tool['description'] is! String ||
          (tool['description'] as String).length > 4000 ||
          tool['parameters'] is! Map || tool['parameters']['type'] != 'object') {
        throw const FormatException('Invalid or duplicate tool definition');
      }
    }
    final auth = raw['authUrl'];
    if (auth != null && (auth is! String ||
        !origins.contains(Uri.tryParse(auth)?.origin))) {
      throw const FormatException('Authentication origin is not declared');
    }
    return ReaderExtension(raw, utf8.decode(entries['plugin.js']!.content as List<int>));
  }
}

/// The dispatcher checks these again on every call, including after revocation.
void requireExtensionPermission(ReaderExtension extension, Set<String> granted,
    String permission, {String? url}) {
  if (!extension.permissions.contains(permission) || !granted.contains(permission)) {
    throw StateError('Extension permission required: $permission');
  }
  if (url != null) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty ||
        !extension.origins.contains(uri.origin)) {
      throw StateError('Network origin is not allowed');
    }
  }
}
