import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:anx_reader/service/extensions/extension_manager.dart';
import 'extension_package_test.dart' show package;

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform old;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('anx-extension-test-');
    old = PathProviderPlatform.instance;
    PathProviderPlatform.instance = Paths(directory.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = old;
    await directory.delete(recursive: true);
  });
  test('only one concurrent mutation may claim the same receipt', () async {
    final manager = ExtensionManager();
    await manager.install(package(), {});
    final results = await Future.wait(List.generate(
        10,
        (_) => manager
            .claimValue('notebooklm', 'receipt-race', {'state': 'started'})));
    expect(results.where((value) => value == null).length, 1);
    expect(results.where((value) => value != null).length, 9);
  });
  test('installation and permission revocation survive restart', () async {
    final manager = ExtensionManager();
    await manager.install(package(), {'network', 'books.read'});
    expect(manager.toolIds, ['ext_notebooklm_list']);
    await manager.setPermission('notebooklm', 'books.read', false);
    final loaded = ExtensionManager();
    await loaded.initialize();
    expect(loaded.grants['notebooklm'], {'network'});
  });
  test('concurrent grant writes are serialized and newest state persists',
      () async {
    final manager = ExtensionManager();
    await manager.install(package(), {'network'});
    await Future.wait([
      manager.setPermission('notebooklm', 'books.read', true),
      manager.setPermission('notebooklm', 'network', false)
    ]);
    final loaded = ExtensionManager();
    await loaded.initialize();
    expect(loaded.grants['notebooklm'], {'books.read'});
  });
  test(
      'plugin storage is namespaced, persists receipts and cannot escape its directory',
      () async {
    final manager = ExtensionManager();
    await manager.install(package(), {});
    await manager.install(package(changes: {'id': 'other'}), {});
    await manager.writeValue(
        'notebooklm', 'receipt-1', {'state': 'started', 'notebookId': 'id'});
    expect(await manager.readValue('notebooklm', 'receipt-1'),
        {'state': 'started', 'notebookId': 'id'});
    expect(await manager.readValue('other', 'receipt-1'), null);
    expect(() => manager.writeValue('notebooklm', '../../escape', {}),
        throwsStateError);
    expect(() => manager.writeValue('notebooklm', 'large', 'x' * 150000),
        throwsStateError);
  });
}
