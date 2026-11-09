import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/models/reader_hint_filter.dart';

void main() {
  test('Show is non-exclusive; Only is independent and persists', () {
    final filter = ReaderHintFilter()
        .choose('Difficulty', 'C1', 'show')
        .choose('topic', 'travel', 'hide');
    expect(filter.toRules()['only'], isEmpty);
    expect(filter.choose('topic', 'travel', 'show').active, false);
    final focus = filter
        .choose('topic', 'food', 'only')
        .choose('difficulty', 'C1', 'only');
    final restored = ReaderHintFilter.fromJson(focus.toJson());
    expect(restored.only, {
      'difficulty': ['C1'],
      'topic': ['food']
    });
    expect(restored.exclude, {
      'topic': ['travel']
    });
    expect(restored.choose('topic', 'food', 'only').only, {
      'difficulty': ['C1']
    });
    expect(restored.choose('topic', 'travel', 'only').exclude, isEmpty);
    final hiddenFocus =
        focus.choose('topic', 'food', 'hide').choose('topic', 'food', 'only');
    expect(hiddenFocus.isHidden('topic', 'food'), true);
    expect(ReaderHintFilter.fromJson('not JSON').active, false);
  });
  test('old Show selections migrate to visible tags, never implicit focus', () {
    final migrated = ReaderHintFilter.fromJson(
        '{"include":{"difficulty":["C1"]},"exclude":{"topic":["travel"]}}');
    expect(migrated.only, isEmpty);
    expect(migrated.exclude, {
      'topic': ['travel']
    });
    expect(migrated.catalog['difficulty'], ['C1']);
  });
  test(
      'categories normalize and deduplicate values, filter catalog may exceed a single annotation',
      () {
    expect(
        normalizeHintTags({
          ' Topic ': ['food', 'FOOD', ' travel ']
        }),
        {
          'topic': ['food', 'travel']
        });
    final values = List.generate(30, (i) => 'topic$i');
    expect(
        ReaderHintFilter(catalog: {'topic': values}).catalog['topic']!.length,
        30);
    expect(() => normalizeHintTags({'topic': values}), throwsFormatException);
  });
}
