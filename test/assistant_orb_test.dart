import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:anx_reader/widgets/ai/assistant_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'all states are accessible in light/dark and reduced motion is still',
      (tester) async {
    tester.view.physicalSize = const Size(440, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    final font = Platform.environment['ANX_PREVIEW_FONT'];
    if (font != null) {
      await tester.runAsync(() async {
        final loader = FontLoader('Preview');
        loader.addFont(
            Future.value(ByteData.sublistView(await File(font).readAsBytes())));
        await loader.load();
      });
    }
    final imageKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: RepaintBoundary(
          key: imageKey,
          child: Row(children: [
            for (final brightness in [Brightness.light, Brightness.dark])
              Expanded(
                  child: Theme(
                data: ThemeData(
                    fontFamily: font == null ? null : 'Preview',
                    colorScheme: ColorScheme.fromSeed(
                        seedColor: const Color(0xff5369cc),
                        brightness: brightness)),
                child: Builder(
                    builder: (context) => ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: Column(children: [
                            const SizedBox(height: 12),
                            for (final state in AssistantOrbState.values)
                              SizedBox(
                                  height: 80,
                                  child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox.square(
                                            dimension: 52,
                                            child: Center(
                                                child: AssistantOrb(
                                                    state: state))),
                                        Text(state.name,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall),
                                      ])),
                          ]),
                        )),
              )),
          ])),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Listening'), findsNWidgets(2));
    expect(
        find.bySemanticsLabel('Working with reader tools'), findsNWidgets(2));
    expect(find.bySemanticsLabel('Disconnected'), findsNWidgets(2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    // Optional review artifact, deliberately separate from golden assertions.
    final path = Platform.environment['ANX_ORB_PREVIEW'];
    if (path != null) {
      final boundary =
          imageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('motion stops when disabled without hiding the state',
      (tester) async {
    Widget view(bool disabled) => MaterialApp(
            home: MediaQuery(
          data: MediaQueryData(disableAnimations: disabled),
          child: const Center(
              child: AssistantOrb(state: AssistantOrbState.thinking)),
        ));
    await tester.pumpWidget(view(false));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(view(true));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.byType(AssistantOrb), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
