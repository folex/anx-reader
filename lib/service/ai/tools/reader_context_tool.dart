import 'dart:convert';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/service/reader_edits/reader_edit_bridge.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:langchain_core/tools.dart';

const readerContextToolIds = [
  'get_reader_selection',
  'get_reader_visible_text',
];

/// Only project the bounded reader-owned snapshot, never arbitrary JS or paths.
Map<String, dynamic> readerContextResult(
  Object? raw, {
  required bool selectionOnly,
}) {
  final decoded = raw is String ? jsonDecode(raw) : raw;
  if (decoded is! Map)
    throw const FormatException('Reader context unavailable');
  String text(String key, int max) {
    final value = decoded[key];
    if (value is! String) return '';
    return value.substring(0, value.length.clamp(0, max));
  }

  final selection = text('selection', 2000);
  final data = <String, dynamic>{
    'title': text('title', 140),
    'chapterHref': text('chapterHref', 500),
    'selection': selection,
    'hasSelection': selection.isNotEmpty,
    'visible': text('visible', selectionOnly ? 2000 : 6000),
    'visibleTruncated': decoded['visibleTruncated'] == true ||
        (decoded['visible'] is String &&
            (decoded['visible'] as String).length >
                (selectionOnly ? 2000 : 6000)),
    'selectionTruncated': decoded['selectionTruncated'] == true ||
        (decoded['selection'] is String &&
            (decoded['selection'] as String).length > 2000),
  };
  final hash = decoded['paragraphHash'];
  final index = decoded['paragraphIndex'];
  if (hash is String &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) &&
      index is int &&
      index >= 0) {
    data['viewAnchor'] = {
      'paragraphHash': hash,
      'paragraphIndex': index,
      'scope':
          'first visible paragraph only; use surrounding text for other paragraphs',
    };
  }
  return data;
}

Tool _buildReaderContextTool(
  AiToolContext context, {
  required bool selectionOnly,
}) {
  final ref = context.ref;
  final handlers = ref.read(readerEditBridgeProvider);
  final reading = ref.read(currentReadingProvider);
  final plan = ChatGptPlan.instance;
  final account = plan.active?.id;
  final revision = plan.requestRevision;
  final enabled = plan.enabled;
  final provider = Prefs().selectedAiService;
  final bookId = reading.book?.id;
  final chapter = context.editChapterHref ?? reading.chapterHref;
  bool current() =>
      ref.context.mounted &&
      ref.read(currentReadingProvider).isReading &&
      ref.read(currentReadingProvider).book?.id == bookId &&
      identical(ref.read(readerEditBridgeProvider), handlers) &&
      plan.active?.id == account &&
      plan.requestRevision == revision &&
      plan.enabled == enabled &&
      Prefs().selectedAiService == provider;
  return Tool.fromFunction<Map<String, dynamic>, String>(
    name: readerContextToolIds[selectionOnly ? 0 : 1],
    description: selectionOnly
        ? 'Read the CURRENT text selection in the open EPUB or PDF, with a bounded portion of visible text. If hasSelection=false do not guess what the user selected; ask or use get_reader_visible_text. Read-only. No screenshot.'
        : 'Read the original text CURRENTLY visible on the reader screen and any selection. Use to refresh context before explaining this/that or adding several annotations. Read-only; this does not return the full chapter or a screenshot. viewAnchor refers only to the first visible paragraph.',
    inputJsonSchema: const {
      'type': 'object',
      'properties': <String, dynamic>{},
      'additionalProperties': false,
    },
    getInputFromJson: (json) {
      if (json.isNotEmpty) throw const FormatException('No arguments accepted');
      return json;
    },
    func: (_) async {
      if (!current() || handlers == null || handlers.bookId != bookId) {
        return jsonEncode({
          'status': 'error',
          'message': 'The book or request changed.',
        });
      }
      try {
        final raw = await handlers.context().timeout(
              const Duration(seconds: 4),
            );
        if (!current() || raw == null)
          throw const FormatException('Context changed');
        final data = readerContextResult(raw, selectionOnly: selectionOnly);
        if (chapter == null || data['chapterHref'] != chapter) {
          throw const FormatException('Chapter changed');
        }
        return jsonEncode({'status': 'ok', 'data': data});
      } catch (_) {
        return jsonEncode({
          'status': 'error',
          'message':
              'Text is unavailable or the chapter changed. Ask the user to return to the intended passage.',
        });
      }
    },
  );
}

final readerSelectionToolDefinition = AiToolDefinition(
  id: readerContextToolIds[0],
  displayNameBuilder: (_) => 'Read selection',
  descriptionBuilder: (_) => 'Get the current selection in the open book.',
  build: (context) => _buildReaderContextTool(context, selectionOnly: true),
);
final readerVisibleTextToolDefinition = AiToolDefinition(
  id: readerContextToolIds[1],
  displayNameBuilder: (_) => 'Read visible text',
  descriptionBuilder: (_) => 'Get the visible text on the current page.',
  build: (context) => _buildReaderContextTool(context, selectionOnly: false),
);
