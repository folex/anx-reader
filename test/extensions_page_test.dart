import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:anx_reader/service/extensions/extension_manager.dart';
import 'package:anx_reader/widgets/extensions/extensions_page.dart';
import 'extension_manager_test.dart' show Paths;
import 'extension_package_test.dart' show package;

void main() {
  testWidgets(
      'extension permissions fit a narrow screen with larger text and can be revoked',
      (tester) async {
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('anx-extension-ui-')))!;
    final old = PathProviderPlatform.instance;
    PathProviderPlatform.instance = Paths(directory.path);
    addTearDown(() async {
      PathProviderPlatform.instance = old;
      await tester.runAsync(() => directory.delete(recursive: true));
    });
    final manager =
        (await tester.runAsync(() async => ExtensionManager.instance))!;
    await tester.runAsync(
        () => manager.install(package(), {'network', 'books.read', 'ui'}));
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(360, 900), textScaler: TextScaler.linear(1.3)),
            child: RepaintBoundary(key: key, child: const ExtensionsPage()))));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('Read book content'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final screenshot = Platform.environment['ANX_EXTENSION_SCREENSHOT'];
    if (screenshot != null) {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(screenshot).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.ensureVisible(find.text('Read book content'));
    await tester.tap(find.text('Read book content'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(manager.grants['notebooklm']!.contains('books.read'), false);
    expect(tester.takeException(), isNull);
  });
}
