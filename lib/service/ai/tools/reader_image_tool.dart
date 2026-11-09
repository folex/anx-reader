import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langchain_core/tools.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/service/reader_edits/reader_edit_bridge.dart';
import 'package:anx_reader/service/reader_edits/epub_edit_store.dart';
import 'package:anx_reader/service/reader_edits/book_image_filter.dart';
import 'ai_tool_registry.dart';
import 'reader_edit_tool.dart';

const readerImageToolActions = {
  'get_book_images': 'list',
  'edit_book_image': 'edit',
  'generate_book_image': 'generate',
  'insert_book_image': 'insert',
};
const readerImageToolIds = [
  'get_book_images',
  'edit_book_image',
  'generate_book_image',
  'insert_book_image'
];

Map<String, dynamic> readerImageSchema(String action) {
  final annotation = readerEditSchema(ruby: false)['properties'] as Map;
  return {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      if (action == 'edit' || action == 'insert') ...{
        'operationId': annotation['operationId'],
        'imageId': {
          'type': 'string',
          'pattern':
              action == 'insert' ? r'^image_[a-f0-9]{64}$' : r'^[a-f0-9]{64}$',
          'description':
              'Exact imageId returned by the image tools for this book. Never guess a path or ID.'
        },
      },
      if (action == 'edit') ...{
        'target': {
          'type': 'string',
          'enum': ['dark', 'all'],
          'description':
              'dark: use the new variant only with a dark reading theme; all: use it for both themes. Original bytes are always retained.'
        },
        'restore': {
          'type': 'boolean',
          'description':
              'Restore the original image in all themes. Omit filters when restoring.'
        },
        'filters': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'preset': {
              'type': 'string',
              'enum': ['custom', 'dark-paper', 'darken'],
              'description':
                  'dark-paper: invert paper/ink while retaining color hues, for light-background drawings and diagrams. darken: dim a photo. Do not blindly invert photographs.'
            },
            'invert': {'type': 'boolean'},
            for (final field in ['brightness', 'contrast', 'saturation'])
              field: {'type': 'number', 'minimum': 0, 'maximum': 2},
            'gamma': {'type': 'number', 'minimum': .25, 'maximum': 4},
            'hue': {'type': 'number', 'minimum': -180, 'maximum': 180},
            'replacements': {
              'type': 'array',
              'maxItems': 8,
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'properties': {
                  'from': {'type': 'string', 'pattern': r'^#[a-fA-F0-9]{6}$'},
                  'to': {'type': 'string', 'pattern': r'^#[a-fA-F0-9]{6}$'},
                  'tolerance': {'type': 'number', 'minimum': 0, 'maximum': 80}
                },
                'required': ['from', 'to']
              }
            },
          },
        },
      },
      if (action == 'insert') ...{
        for (final key in [
          'quote',
          'contextBefore',
          'contextAfter',
          'paragraphHash',
          'paragraphIndex',
          'occurrence'
        ])
          key: annotation[key],
        'caption': {
          'type': 'string',
          'maxLength': 400,
          'description':
              'Brief caption; mark generated imagery as an AI illustration, not an original plate from the book.'
        },
      },
      if (action == 'generate') 'operationId': annotation['operationId'],
      if (action == 'generate')
        'prompt': {
          'type': 'string',
          'minLength': 1,
          'maxLength': 4000,
          'description':
              'Illustration based on the current excerpt and user request. Include period/clothes/setting details; no future plot spoilers. Generation uses the separately configured image API; it is not covered by the ChatGPT sign-in route.'
        },
    },
    'required': switch (action) {
      'edit' => ['operationId', 'imageId', 'target'],
      'insert' => ['operationId', 'imageId', 'quote'],
      'generate' => ['operationId', 'prompt'],
      _ => <String>[]
    },
  };
}

Map<String, dynamic> parseReaderImageInput(
    Map<String, dynamic> input, String action) {
  if (utf8.encode(jsonEncode(input)).length > 16000)
    throw const FormatException('Image tool input is too large');
  final schema = readerImageSchema(action);
  final properties = schema['properties'] as Map;
  if (input.keys.any((key) => !properties.containsKey(key)))
    throw const FormatException('Unknown image tool fields');
  for (final key in schema['required'] as List) {
    if (input[key] == null) throw FormatException('Missing $key');
  }
  for (final field in properties.entries) {
    final value = input[field.key];
    if (value == null) continue;
    final spec = field.value as Map;
    if (spec['type'] == 'string' && value is! String ||
        spec['type'] == 'boolean' && value is! bool ||
        spec['type'] == 'object' && value is! Map ||
        spec['type'] == 'integer' && value is! int)
      throw FormatException('Invalid ${field.key}');
    if (value is String &&
        (spec['maxLength'] is int && value.length > spec['maxLength'] ||
            spec['pattern'] is String &&
                !RegExp(spec['pattern']).hasMatch(value) ||
            value.trim().isEmpty))
      throw FormatException('Invalid ${field.key}');
    if (spec['enum'] is List && !(spec['enum'] as List).contains(value))
      throw FormatException('Invalid ${field.key}');
  }
  if (action == 'insert') {
    parseReaderEditInput({
      for (final key in [
        'operationId',
        'quote',
        'contextBefore',
        'contextAfter',
        'paragraphHash',
        'paragraphIndex',
        'occurrence'
      ])
        if (input.containsKey(key)) key: input[key],
      'text': 'image'
    }, ruby: false);
  }
  if (action == 'edit' && input['restore'] == true && input['filters'] != null)
    throw const FormatException('Use restore OR filters');
  return {
    ...input,
    if (input['filters'] != null)
      'filters': parseBookImageFilters(
          Map<String, dynamic>.from(input['filters'] as Map)),
    'action': action
  };
}

Tool buildReaderImageTool(WidgetRef ref, String name, String? chapter) {
  final handlers = ref.read(readerEditBridgeProvider);
  final book = ref.read(currentReadingProvider).book?.id;
  final plan = ChatGptPlan.instance;
  final account = plan.active?.id,
      revision = plan.requestRevision,
      provider = Prefs().selectedAiService;
  final usesPlan = plan.enabled;
  final boundChapter = chapter ?? ref.read(currentReadingProvider).chapterHref;
  bool current() =>
      ref.context.mounted &&
      ref.read(currentReadingProvider).isReading &&
      ref.read(currentReadingProvider).book?.id == book &&
      identical(ref.read(readerEditBridgeProvider), handlers) &&
      plan.active?.id == account &&
      plan.requestRevision == revision &&
      plan.enabled == usesPlan &&
      Prefs().selectedAiService == provider;
  final action = readerImageToolActions[name]!;
  return Tool.fromFunction<Map<String, dynamic>, String>(
    name: name,
    description: switch (action) {
      'list' =>
        'List embedded images in the bound EPUB chapter, prioritizing those currently visible, and private pending imported/generated images (most recent first) ready for insertion. Use returned imageId values for edits. No images are uploaded.',
      'edit' =>
        'Locally recolor ONE embedded still image on the phone: invert, brightness, contrast, saturation, gamma, hue or color replacement. Use ONLY on user request. dark target preserves the original for light reading; restore returns to original. Every adjustment starts from original bytes, not cumulative filters. Reuse operationId on retry; after a successful edit list images again for fresh IDs.',
      'generate' =>
        'Generate an illustration via the separately configured image API. Use only when user explicitly requests a new image. Returns a private imageId; then use insert_book_image to embed it after an exact passage. Never say it is inserted until insertion succeeds. Use a stable operationId and reuse it on retries. Completed generations are reused; an uncertain prior paid attempt is never sent again with that ID.',
      _ =>
        'Embed an imported/generated image after the paragraph containing an exact quote. Requires imageId from generation/import and exact context/hash as for footnotes. Writes to EPUB atomically with a backup. Reuse operationId on retry. No arbitrary HTML or device paths.',
    },
    inputJsonSchema: readerImageSchema(action),
    getInputFromJson: (input) => parseReaderImageInput(input, action),
    func: (input) async {
      if (!current() ||
          handlers?.images == null ||
          boundChapter == null ||
          boundChapter.isEmpty)
        return jsonEncode({
          'status': 'error',
          'message': 'Open the book chapter before using image tools.'
        });
      try {
        final result = await handlers!.images!(
            {...input, 'chapterHref': boundChapter}, current);
        if (!current())
          return jsonEncode({
            'status': 'error',
            'message':
                'The reading context changed. Do not repeat a generation or edit until its result is checked.'
          });
        return jsonEncode({'status': 'ok', 'data': result});
      } on EpubEditException catch (error) {
        return jsonEncode({'status': 'error', 'message': error.message});
      } on FormatException catch (error) {
        return jsonEncode({'status': 'error', 'message': error.message});
      } catch (_) {
        return jsonEncode({
          'status': 'error',
          'message':
              'Image operation could not be completed. Check the result before retrying; the original image is retained.'
        });
      }
    },
  );
}

final readerImageToolDefinitions = [
  for (final id in readerImageToolIds)
    AiToolDefinition(
      id: id,
      displayNameBuilder: (_) => switch (id) {
        'get_book_images' => 'Read book images',
        'edit_book_image' => 'Adjust book image',
        'generate_book_image' => 'Generate illustration',
        _ => 'Insert illustration'
      },
      descriptionBuilder: (_) =>
          'Book illustrations and local image adjustments.',
      build: (context) =>
          buildReaderImageTool(context.ref, id, context.editChapterHref),
    )
];
