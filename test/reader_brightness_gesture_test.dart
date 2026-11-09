import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/reading_page/reader_brightness_gesture.dart';

class RecordingPlatformView extends PlatformViewController {
  final events = <PointerEvent>[];
  @override
  int get viewId => 7;
  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async =>
      events.add(event);
  @override
  Future<void> dispose() async {}
  @override
  Future<void> clearFocus() async {}
}

void androidTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.anxcye.anx_reader/reader_brightness');
  late List<MethodCall> calls;
  late double brightness;

  setUp(() {
    calls = [];
    brightness = 0.5;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setBrightness') {
            brightness = (call.arguments['value'] as num).toDouble();
          }
          return {'active': true, 'brightness': brightness};
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<RecordingPlatformView> mount(
    WidgetTester tester, {
    bool enabled = true,
    bool canStart = true,
  }) async {
    final controller = RecordingPlatformView();
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: ReaderBrightnessGesture(
              enabled: enabled,
              canStart: () => canStart,
              child: PlatformViewSurface(
                controller: controller,
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                gestureRecognizers:
                    const <Factory<OneSequenceGestureRecognizer>>{},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  Future<void> edgeDrag(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(const Offset(8, 300));
    await gesture.moveBy(Offset(0, dy.isNegative ? -30 : 30));
    await tester.pump();
    await gesture.moveBy(Offset(0, dy));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  androidTestWidgets('left edge tap reaches actual PlatformViewSurface arena', (
    tester,
  ) async {
    final view = await mount(tester);
    await tester.tapAt(const Offset(8, 250));
    await tester.pump();
    expect(view.events.whereType<PointerDownEvent>(), hasLength(1));
    expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
    expect(calls.where((c) => c.method == 'setBrightness'), isEmpty);
  });

  androidTestWidgets('left edge horizontal page swipe reaches platform view', (
    tester,
  ) async {
    final view = await mount(tester);
    await tester.dragFrom(const Offset(8, 300), const Offset(150, 0));
    await tester.pump();
    expect(view.events.whereType<PointerMoveEvent>(), isNotEmpty);
    expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
    expect(calls.where((c) => c.method == 'setBrightness'), isEmpty);
  });

  androidTestWidgets(
    'ordinary text vertical scrolling outside 18dp is untouched',
    (tester) async {
      final view = await mount(tester);
      await tester.dragFrom(const Offset(40, 300), const Offset(0, -180));
      await tester.pump();
      expect(view.events.whereType<PointerMoveEvent>(), isNotEmpty);
      expect(calls.where((c) => c.method == 'setBrightness'), isEmpty);
    },
  );

  androidTestWidgets(
    'short edge movement under vertical threshold passes through',
    (tester) async {
      final view = await mount(tester);
      await tester.dragFrom(const Offset(8, 300), const Offset(0, -6));
      await tester.pump();
      expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
      expect(calls.where((c) => c.method == 'setBrightness'), isEmpty);
    },
  );

  androidTestWidgets(
    'edge vertical drag wins arena, raises brightness, HUD does not intercept',
    (tester) async {
      final view = await mount(tester);
      await edgeDrag(tester, -180);
      expect(brightness, greaterThan(0.5));
      expect(brightness, lessThanOrEqualTo(1));
      expect(view.events, isEmpty);
      expect(
        find.byKey(const ValueKey('reader-brightness-hud')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(200, 300));
      await tester.pump();
      expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
      await tester.pump(const Duration(milliseconds: 901));
      expect(find.byKey(const ValueKey('reader-brightness-hud')), findsNothing);
    },
  );

  androidTestWidgets(
    'brightness clamps to ordinary Android minimum and maximum',
    (tester) async {
      await mount(tester);
      await edgeDrag(tester, -1200);
      expect(brightness, 1);
      await edgeDrag(tester, 1200);
      expect(brightness, 0);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  androidTestWidgets(
    'disabled feature preserves edge scroll and never enters native reader',
    (tester) async {
      final view = await mount(tester, enabled: false);
      await tester.dragFrom(const Offset(8, 300), const Offset(0, -180));
      await tester.pump();
      expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
      expect(calls, isEmpty);
    },
  );

  androidTestWidgets(
    'covered reader/menu gate rejects before claiming vertical arena',
    (tester) async {
      final view = await mount(tester, canStart: false);
      await tester.dragFrom(const Offset(8, 300), const Offset(0, -180));
      await tester.pump();
      expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
      expect(
        calls.where(
          (c) => c.method == 'getBrightness' || c.method == 'setBrightness',
        ),
        isEmpty,
      );
    },
  );

  androidTestWidgets('disposing reader restores native brightness', (
    tester,
  ) async {
    await mount(tester);
    await edgeDrag(tester, -100);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.method, 'exitReader');
  });

  androidTestWidgets('late activation from old toggle does not arm a new owner', (
    tester,
  ) async {
    final activations = <Completer<Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'enterReader') {
            final pending = Completer<Object?>();
            activations.add(pending);
            return pending.future;
          }
          if (call.method == 'setBrightness') {
            brightness = (call.arguments['value'] as num).toDouble();
          }
          return {'active': true, 'brightness': brightness};
        });
    final enabled = ValueNotifier(true);
    final view = RecordingPlatformView();
    await tester.pumpWidget(MaterialApp(
      home: Align(alignment: Alignment.topLeft, child: SizedBox(width: 400, height: 600,
        child: ValueListenableBuilder<bool>(valueListenable: enabled, builder: (context, value, _) {
          return ReaderBrightnessGesture(enabled: value, child: PlatformViewSurface(
            controller: view, hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          ));
        }),
      )),
    ));
    await tester.pump();
    enabled.value = false; await tester.pump();
    enabled.value = true; await tester.pump();
    expect(activations, hasLength(2));
    final owners = calls.where((c) => c.method == 'enterReader').map((c) => c.arguments['owner']).toList();
    expect(owners[0], isNot(owners[1]));
    activations[0].complete({'active': true, 'brightness': 0.5}); await tester.pump();
    await edgeDrag(tester, -100);
    expect(calls.where((c) => c.method == 'getBrightness'), isEmpty);
    expect(view.events.whereType<PointerUpEvent>(), hasLength(1));
    activations[1].complete({'active': true, 'brightness': 0.5}); await tester.pump();
    await edgeDrag(tester, -100);
    final writes = calls.where((c) => c.method == 'setBrightness');
    expect(writes, isNotEmpty);
    expect(writes.every((c) => c.arguments['owner'] == owners[1]), isTrue);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
    enabled.dispose();
  });
}
