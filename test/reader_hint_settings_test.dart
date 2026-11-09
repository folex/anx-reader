import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:anx_reader/models/reader_hint_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/models/reader_hint_filter.dart';
import 'package:anx_reader/widgets/ai/reader_hint_settings.dart';

void main() {
  testWidgets(
      'custom filters fit narrow large-text screen, save and clear independently of density',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ReaderHintFilter? saved, previewed;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 900), textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: ReaderHintSettings(
                    tags: const {
                  'difficulty': ['C1', 'B1']
                },
                    filter: ReaderHintFilter(),
                    preview: (filter) async {
                      previewed = filter;
                      return ReaderHintPreview(
                          matches: 1,
                          image: base64Decode(
                              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=='));
                    },
                    setFilter: (filter) async {
                      saved = filter;
                    })))));
    expect(find.byType(DropdownButton<int>), findsNothing);
    await tester.ensureVisible(find.byTooltip('Hide difficulty: C1'));
    await tester.tap(find.byTooltip('Hide difficulty: C1'));
    await tester.pumpAndSettle();
    expect(saved!.exclude, {
      'difficulty': ['C1']
    });
    await tester.tap(find.byTooltip('Show difficulty: C1'));
    await tester.pumpAndSettle();
    expect(saved!.active, false);
    await tester.tap(find.byTooltip('Only difficulty: C1'));
    await tester.pumpAndSettle();
    expect(saved!.only, {
      'difficulty': ['C1']
    });
    final beforePreview = saved;
    await tester.ensureVisible(find.text('Preview'));
    await tester.tap(find.text('Preview'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(previewed!.only, {
      'difficulty': ['C1']
    });
    expect(find.byTooltip('Close preview'), findsOneWidget);
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('difficulty'));
    await tester.tap(find.text('difficulty'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(previewed!.only['difficulty'], unorderedEquals(['C1', 'B1']));
    expect(identical(saved, beforePreview), isTrue);
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('B1'));
    await tester.tap(find.text('B1'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(previewed!.only, {
      'difficulty': ['B1']
    });
    expect(previewed!.exclude, isEmpty);
    expect(identical(saved, beforePreview), isTrue);
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Clear filters'));
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(saved!.active, false);
    expect(saved!.catalog['difficulty'], unorderedEquals(['C1', 'B1']));
    await tester.ensureVisible(find.text('Add tag'));
    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'my scale');
    await tester.enterText(find.byType(TextField).at(1), 'Expert');
    await tester.ensureVisible(find.text('Add').last);
    await tester.tap(find.text('Add').last);
    await tester.pumpAndSettle();
    expect(saved!.catalog['my scale'], ['Expert']);
    expect(tester.takeException(), isNull);
  });
}
