import 'dart:convert';
import 'dart:io';
import 'package:anx_reader/models/reader_hint_filter.dart';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/service/reader_edits/reader_edit_bridge.dart';
import 'package:anx_reader/service/reader_edits/epub_edit_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langchain_core/tools.dart';

const readerEditToolIds = [
  'add_book_footnote',
  'add_book_ruby',
  'add_book_highlight'
];

Map<String, dynamic> _readerEditSingleSchema(
        {required bool ruby, bool highlight = false}) =>
    {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'operationId': {
          'type': 'string',
          'pattern': r'^[A-Za-z0-9._-]{1,80}$',
          'description':
              'Unique stable edit id. Reuse this SAME id on retry, never generate a new id for a retry.',
        },
        'chapterHref': {
          'type': 'string',
          'maxLength': 500,
          'description':
              'Exact current chapter href from supplied reader context; omit to use the bound current chapter. Never guess a path.',
        },
        'quote': {
          'type': 'string',
          'maxLength': 500,
          'description':
              'Exact Spanish word/phrase from original book text, without glosses or footnote digits.',
        },
        'contextBefore': {
          'type': 'string',
          'maxLength': 300,
          'description':
              'Exact short text immediately before the quote. Supply before or after context, or a verified paragraphHash.',
        },
        'contextAfter': {
          'type': 'string',
          'maxLength': 300,
          'description': 'Exact short text immediately after the quote.',
        },
        'paragraphHash': {
          'type': 'string',
          'pattern': r'^[a-f0-9]{64}$',
          'description':
              'Only use a hash supplied in reader context or a prior tool result, never invent one.',
        },
        'paragraphIndex': {
          'type': 'integer',
          'minimum': 0,
          'description':
              'Only use the verified index supplied with paragraphHash in reader context or a prior result; never guess.',
        },
        'occurrence': {
          'type': 'integer',
          'minimum': 1,
          'description':
              'Explicit 1-based occurrence among exact quote+context matches. Omit unless user/context identifies it; ambiguous matches are rejected.',
        },
        'text': {
          'type': 'string',
          'maxLength': ruby ? 32 : 1200,
          'description': ruby
              ? 'Very brief plain-text gloss, preferably <=25 characters. Put longer grammar in a footnote. No HTML.'
              : 'Concise plain-text explanation, usually 2–5 sentences. No HTML or scripts.',
        },
        if (highlight)
          'color': {
            'type': 'string',
            'pattern': r'^#[a-fA-F0-9]{6}$',
            'description': 'Highlight color #RRGGBB. Default #FFE082.'
          },
        'group': {
          'type': 'string',
          'maxLength': 64,
          'description':
              'Toggleable group label, e.g. Gramática or Vocabulario.',
        },
        'tier': {
          'type': 'integer',
          'enum': [1, 2, 3],
          'description':
              '1=difficult/essential shown in rare, 2=medium, 3=common only in many. Default3.',
        },
        'tags': {
          'type': 'object',
          'maxProperties': 16,
          'additionalProperties': {
            'type': 'array',
            'minItems': 1,
            'maxItems': 16,
            'items': {'type': 'string', 'minLength': 1, 'maxLength': 64},
          },
          'description':
              'Optional arbitrary categories with values, e.g. {"difficulty":["C1"],"topic":["food"],"grammar":["subjunctive"]}. User-defined categories/levels are allowed. These are filterable tags, not inferred certainty. Use the user requested vocabulary; do not guess CEFR difficulty. Category names max32 characters. Untagged legacy hints keep their original levels.',
        },
        if (ruby)
          'mode': {
            'type': 'string',
            'enum': ['append', 'overwrite'],
            'description':
                'For an already annotated word: append keeps existing glosses and adds this one; overwrite replaces them. Omit to reject overlap. Use one items batch for an entire paragraph.',
          },
        if (ruby)
          'alignment': {
            'type': 'string',
            'enum': ['left', 'center', 'right'],
            'description':
                'Place the gloss above the first, middle or last single word of the quoted phrase; never stretch it across all words. Default left.',
          },
      },
      'required': ['operationId', 'quote', if (!highlight) 'text'],
    };

/// A batch shares one bound chapter and is committed atomically.
Map<String, dynamic> readerEditSchema(
    {required bool ruby, bool highlight = false}) {
  final single = _readerEditSingleSchema(ruby: ruby, highlight: highlight);
  final item = {
    ...single,
    'properties': {...single['properties'] as Map}..remove('chapterHref'),
  };
  return {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      ...single['properties'] as Map,
      'items': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 50,
        'items': item,
        'description':
            'Atomic batch of up to 50 edits in this same chapter. Every item needs a stable operationId and exact anchor. Prefer a batch for many annotations; one invalid item cancels the entire batch.',
      },
    },
    'oneOf': [
      {
        'required': ['items'],
        'not': {
          'anyOf': [
            for (final key in [
              'operationId',
              'quote',
              'text',
              'contextBefore',
              'contextAfter',
              'paragraphHash',
              'paragraphIndex',
              'occurrence',
              'group',
              'tier',
              'tags',
              'alignment',
              'mode',
              'color',
            ])
              {
                'required': [key],
              },
          ],
        },
      },
      {
        'required': ['operationId', 'quote', if (!highlight) 'text'],
        'not': {
          'required': ['items'],
        },
      },
    ],
  };
}

Map<String, dynamic> parseReaderEditInput(
  Map<String, dynamic> json, {
  required bool ruby,
  bool highlight = false,
}) {
  if (utf8.encode(jsonEncode(json)).length > 128 * 1024) {
    throw const FormatException('Input too large');
  }
  if (json.containsKey('items')) {
    if (json.keys.any((key) => !['items', 'chapterHref'].contains(key))) {
      throw const FormatException('Use single fields OR items, not both');
    }
    final items = json['items'];
    if (items is! List || items.isEmpty || items.length > 50) {
      throw const FormatException('Batch requires 1–50 items');
    }
    final chapter = json['chapterHref'];
    if (chapter != null &&
        (chapter is! String || chapter.isEmpty || chapter.length > 500)) {
      throw const FormatException('Invalid chapterHref');
    }
    final parsed = <Map<String, dynamic>>[];
    for (final item in items) {
      if (item is! Map<String, dynamic> ||
          item.containsKey('items') ||
          item.containsKey('chapterHref')) {
        throw const FormatException(
          'Batch items must be single edits in the bound chapter',
        );
      }
      parsed.add(parseReaderEditInput(item, ruby: ruby, highlight: highlight));
    }
    return {'items': parsed, if (chapter != null) 'chapterHref': chapter};
  }
  final properties =
      _readerEditSingleSchema(ruby: ruby, highlight: highlight)['properties']
          as Map;
  if (json.keys.any((key) => !properties.containsKey(key)) ||
      jsonEncode(json).length > 16000) {
    throw const FormatException('Unknown fields or input too large');
  }
  for (final name in ['operationId', 'quote', if (!highlight) 'text']) {
    if (json[name] is! String || (json[name] as String).trim().isEmpty) {
      throw FormatException('Missing $name');
    }
  }
  for (final entry in properties.entries) {
    final value = json[entry.key];
    if (value == null) continue;
    final schema = entry.value as Map;
    if (schema['type'] == 'string' && value is! String ||
        schema['type'] == 'integer' && value is! int) {
      throw FormatException('Invalid ${entry.key}');
    }
    if (value is String &&
        (schema['maxLength'] is int && value.length > schema['maxLength'] ||
            schema['pattern'] is String &&
                !RegExp(schema['pattern']).hasMatch(value))) {
      throw FormatException('Invalid ${entry.key}');
    }
    if (schema['enum'] is List && !(schema['enum'] as List).contains(value) ||
        schema['minimum'] is int && value is int && value < schema['minimum']) {
      throw FormatException('Invalid ${entry.key}');
    }
  }
  if ((json['contextBefore']?.toString().trim() ?? '').isEmpty &&
      (json['contextAfter']?.toString().trim() ?? '').isEmpty &&
      json['paragraphHash'] == null) {
    throw const FormatException(
      'Exact quote needs contextBefore/contextAfter or a verified paragraphHash',
    );
  }
  return {
    ...json,
    if (json.containsKey('tags')) 'tags': normalizeHintTags(json['tags']),
    'type': highlight
        ? 'highlight'
        : ruby
            ? 'ruby'
            : 'footnote',
    if (highlight) 'text': json['text'] ?? '',
    if (highlight)
      'color': (json['color'] ?? '#FFE082').toString().toLowerCase()
  };
}

Tool buildReaderEditTool(
  WidgetRef ref, {
  required bool ruby,
  bool highlight = false,
  String? boundChapterHref,
}) {
  final reading = ref.read(currentReadingProvider);
  final handlers = ref.read(readerEditBridgeProvider);
  final plan = ChatGptPlan.instance;
  final account = plan.active?.id;
  final revision = plan.requestRevision;
  final usesPlan = plan.enabled;
  final provider = Prefs().selectedAiService;
  final bookId = reading.book?.id;
  final chapterHref = boundChapterHref ?? reading.chapterHref;
  bool current() =>
      ref.context.mounted &&
      ref.read(currentReadingProvider).isReading &&
      ref.read(currentReadingProvider).book?.id == bookId &&
      identical(ref.read(readerEditBridgeProvider), handlers) &&
      plan.active?.id == account &&
      plan.requestRevision == revision &&
      plan.enabled == usesPlan &&
      Prefs().selectedAiService == provider;
  final name = readerEditToolIds[highlight
      ? 2
      : ruby
          ? 1
          : 0];
  return Tool.fromFunction<Map<String, dynamic>, String>(
    name: name,
    description:
        '${highlight ? 'Persist a colored highlight with an optional plain-text comment at an exact phrase' : ruby ? 'Persist a very brief gloss above one exact Spanish word/phrase' : 'Persist a concise popup footnote anchored to one exact Spanish word/phrase'} in the CURRENT EPUB or PDF page. Use ONLY when user asks to add/save content, not for ordinary explanation. Original text stays visible. EPUB changes are backed up in the source ZIP; PDF annotations are saved in a persistent Anx sidecar without changing the PDF bytes. Exact quote plus surrounding context is required. No arbitrary HTML/JS, no filesystem paths. Use items for an atomic batch of up to 50 annotations, with one save/reload. Current chapter href: ${chapterHref ?? '(unavailable)'}.',
    inputJsonSchema: readerEditSchema(ruby: ruby, highlight: highlight),
    getInputFromJson: (json) =>
        parseReaderEditInput(json, ruby: ruby, highlight: highlight),
    func: (input) async {
      if (!current() || handlers == null || handlers.bookId != bookId) {
        return jsonEncode({
          'status': 'error',
          'message':
              'The book, account, or request changed. Nothing was saved.',
        });
      }
      try {
        if (chapterHref == null ||
            chapterHref.isEmpty ||
            input['chapterHref'] != null &&
                input['chapterHref'] != chapterHref) {
          throw const FormatException(
            'Use the exact chapterHref bound to this request; chapter is unavailable or mismatched',
          );
        }
        final result = await handlers.apply({
          ...input,
          'chapterHref': chapterHref,
        }, current);
        if (!current())
          return jsonEncode({
            'status': 'error',
            'message':
                'Context changed after the operation. Do not retry with a new operationId.',
          });
        return jsonEncode({'status': 'ok', 'data': result});
      } on FileSystemException {
        return jsonEncode({
          'status': 'error',
          'message':
              'Could not safely save the book annotation. The original file is intact.',
        });
      } on EpubEditException catch (error) {
        return jsonEncode({'status': 'error', 'message': error.message});
      } on FormatException catch (error) {
        return jsonEncode({'status': 'error', 'message': error.message});
      } catch (_) {
        return jsonEncode({
          'status': 'error',
          'message':
              'Could not validate or save the annotation. Check the result before retrying with a new operationId.',
        });
      }
    },
  );
}

final addBookFootnoteToolDefinition = AiToolDefinition(
  id: readerEditToolIds[0],
  displayNameBuilder: (_) => 'Add book footnote',
  descriptionBuilder: (_) =>
      'Save an explanation at an exact phrase in the current book.',
  build: (context) => buildReaderEditTool(
    context.ref,
    ruby: false,
    boundChapterHref: context.editChapterHref,
  ),
);
final addBookRubyToolDefinition = AiToolDefinition(
  id: readerEditToolIds[1],
  displayNameBuilder: (_) => 'Add word hint',
  descriptionBuilder: (_) =>
      'Save a brief translation above the start, middle, or end of a phrase.',
  build: (context) => buildReaderEditTool(
    context.ref,
    ruby: true,
    boundChapterHref: context.editChapterHref,
  ),
);

final addBookHighlightToolDefinition = AiToolDefinition(
  id: readerEditToolIds[2],
  displayNameBuilder: (_) => 'Highlight text',
  descriptionBuilder: (_) =>
      'Color an exact phrase with an optional comment in EPUB or PDF.',
  build: (context) => buildReaderEditTool(context.ref,
      ruby: false, highlight: true, boundChapterHref: context.editChapterHref),
);
