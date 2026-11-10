import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/service/ai/tools/reader_edit_tool.dart';

void main() {
  final valid = <String, dynamic>{
    'operationId': 'edit-1',
    'quote': 'palabra',
    'contextBefore': 'una',
    'text': 'слово',
  };
  test('custom tag categories survive single and batch annotations', () {
    final tagged = {
      ...valid,
      'tags': {
        'difficulty': ['C1'],
        'topic': ['food', 'travel']
      }
    };
    expect(parseReaderEditInput(tagged, ruby: true)['tags'], tagged['tags']);
    final batch = parseReaderEditInput({
      'items': [tagged]
    }, ruby: false);
    expect(batch['items'][0]['tags'], tagged['tags']);
    for (final tags in [
      [],
      {'topic': 'food'},
      {
        'topic': [1]
      },
      {
        'topic': ['']
      },
      {'topic': List.filled(17, 'x')}
    ]) {
      expect(() => parseReaderEditInput({...valid, 'tags': tags}, ruby: true),
          throwsFormatException);
    }
  });
  test('valid input preserves exact anchor and adds narrow type', () {
    expect(parseReaderEditInput(valid, ruby: false)['type'], 'footnote');
    expect(
      parseReaderEditInput({
        ...valid,
        'alignment': 'right',
      }, ruby: true)['alignment'],
      'right',
    );
  });
  test('ruby supports explicit append and overwrite in one batch', () {
    final batch = parseReaderEditInput({
      'items': [
        {...valid, 'mode': 'append'},
        {...valid, 'operationId': 'replace', 'mode': 'overwrite'},
      ],
    }, ruby: true);
    expect(batch['items'][0]['mode'], 'append');
    expect(batch['items'][1]['mode'], 'overwrite');
    expect(() => parseReaderEditInput({...valid, 'mode': 'delete'}, ruby: true),
        throwsFormatException);
    for (final highlight in [false, true]) {
      expect(
          parseReaderEditInput({...valid, 'mode': 'overwrite'},
              ruby: false, highlight: highlight)['mode'],
          'overwrite');
      expect(
          parseReaderEditInput({...valid, 'mode': 'append'},
              ruby: false, highlight: highlight)['mode'],
          'append');
    }
  });
  test('ambiguous, unbounded and arbitrary fields are rejected', () {
    for (final input in [
      {...valid}..remove('contextBefore'),
      {...valid, 'text': 'x' * 33},
      {...valid, 'script': 'alert(1)'},
      {...valid, 'tier': 0},
      {...valid, 'paragraphIndex': -1},
      {...valid, 'operationId': '../unsafe'},
    ]) {
      expect(
        () => parseReaderEditInput(input, ruby: true),
        throwsFormatException,
      );
    }
  });
  test('verified paragraph anchors work without model supplied context', () {
    final input = {...valid, 'paragraphHash': 'a' * 64, 'paragraphIndex': 3}
      ..remove('contextBefore');
    expect(parseReaderEditInput(input, ruby: false)['paragraphIndex'], 3);
  });
  test('batch is bounded, same-chapter and validates every item', () {
    final parsed = parseReaderEditInput({
      'chapterHref': 'c.xhtml',
      'items': [
        valid,
        {...valid, 'operationId': 'edit-2'},
      ],
    }, ruby: false);
    expect((parsed['items'] as List).length, 2);
    expect(parsed['items'][0]['type'], 'footnote');
    for (final input in [
      {'items': []},
      {'items': List.filled(51, valid)},
      {
        'items': [valid],
        'quote': 'mixed',
      },
      {
        'items': [
          {...valid, 'chapterHref': 'other.xhtml'},
        ],
      },
      {
        'items': [
          valid,
          {...valid, 'script': 'evil'},
        ],
      },
      {
        'items': [
          valid,
          {...valid, 'contextBefore': ''},
        ],
      },
      {
        'items': [
          {
            'items': [valid],
          },
        ],
      },
    ])
      expect(
        () => parseReaderEditInput(input, ruby: false),
        throwsFormatException,
      );
  });
  test('all three bounded mutation tools are exposed to voice', () {
    expect(readerEditToolIds,
        ['add_book_footnote', 'add_book_ruby', 'add_book_highlight']);
    expect(
      (readerEditSchema(ruby: true)['properties'] as Map)['text']['maxLength'],
      32,
    );
  });
  test(
      'highlight accepts a color and optional comment in single or batch input',
      () {
    final input = {...valid, 'color': '#40a0ff'}..remove('text');
    final parsed = parseReaderEditInput(input, ruby: false, highlight: true);
    expect(parsed['type'], 'highlight');
    expect(parsed['color'], '#40a0ff');
    final batch = parseReaderEditInput({
      'items': [
        input,
        {...valid, 'operationId': 'hi-2', 'text': 'Useful contrast'}
      ]
    }, ruby: false, highlight: true);
    expect(batch['items'][1]['text'], 'Useful contrast');
    expect(
        () => parseReaderEditInput({...input, 'color': 'url(x)'},
            ruby: false, highlight: true),
        throwsFormatException);
  });
}
