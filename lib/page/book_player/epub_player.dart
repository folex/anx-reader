import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/models/reader_hint_filter.dart';
import 'package:anx_reader/models/reader_hint_preview.dart';
import 'package:anx_reader/service/reader_edits/reader_book_images.dart';
import 'package:anx_reader/service/reader_edits/book_image_assets.dart';
import 'package:anx_reader/service/reader_edits/book_image_generation.dart';
import 'package:anx_reader/models/footnote_appearance.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:anx_reader/service/reader_edits/reader_edit_bridge.dart';
import 'package:anx_reader/service/reader_edits/epub_edit_store.dart';
import 'package:anx_reader/service/reader_edits/pdf_hint_store.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/service/voice/reader_assistant_context.dart';
import 'package:anx_reader/service/ai/tools/repository/book_content_search_repository.dart';

import 'package:anx_reader/widgets/reading_page/reader_brightness_gesture.dart';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/enums/page_turn_mode.dart';
import 'package:anx_reader/enums/reading_info.dart';
import 'package:anx_reader/enums/translation_mode.dart';
import 'package:anx_reader/enums/writing_mode.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/models/font_model.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/models/reading_rules.dart';
import 'package:anx_reader/models/search_result_model.dart';
import 'package:anx_reader/models/toc_item.dart';
import 'package:anx_reader/page/book_player/image_viewer.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/book_toc.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/utils/coordinates_to_part.dart';
import 'package:anx_reader/utils/js/convert_dart_color_to_js.dart';
import 'package:anx_reader/utils/js/js_call.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:anx_reader/utils/webView/webview_console_message.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/context_menu/context_menu.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/diagram.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/types_and_icons.dart';
import 'package:anx_reader/widgets/reading_page/style_widget.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

import 'minute_clock.dart';

class EpubPlayer extends ConsumerStatefulWidget {
  final Book book;
  final String? cfi;
  final Function showOrHideAppBarAndBottomBar;
  final Function onLoadEnd;
  final List<ReadTheme> initialThemes;
  final Function updateParent;

  const EpubPlayer({
    super.key,
    required this.showOrHideAppBarAndBottomBar,
    required this.book,
    this.cfi,
    required this.onLoadEnd,
    required this.initialThemes,
    required this.updateParent,
  });

  @override
  ConsumerState<EpubPlayer> createState() => EpubPlayerState();
}

class EpubPlayerState extends ConsumerState<EpubPlayer>
    with TickerProviderStateMixin {
  late InAppWebViewController webViewController;
  late ContextMenu contextMenu;
  String cfi = '';
  double percentage = 0.0;
  String chapterTitle = '';
  String chapterHref = '';
  int chapterCurrentPage = 0;
  int chapterTotalPages = 0;
  OverlayEntry? contextMenuEntry;
  AnimationController? _animationController;
  Animation<double>? _animation;
  bool showHistory = false;
  bool _hintPreviewActive = false;

  Future<ReaderHintPreview> captureHintPreview(ReaderHintFilter filter) async {
    if (_hintPreviewActive) {
      throw StateError('A hint preview is already active');
    }
    _hintPreviewActive = true;
    bool started = false;
    try {
      final result = await webViewController.callAsyncJavaScript(
        functionBody: 'return await ${jsCall('beginReaderHintPreview', [filter.toRules()])};');
      final metadata = result?.value;
      if (metadata is! Map || metadata['matches'] is! num) {
        throw StateError('The chapter is not ready for preview');
      }
      started = true;
      final image = await webViewController.takeScreenshot();
      if (image == null) {
        throw StateError('Could not capture the book preview');
      }
      return ReaderHintPreview(
        image: image, matches: (metadata['matches'] as num).toInt());
    } finally {
      try {
        if (mounted) {
          final restored = await webViewController.callAsyncJavaScript(
            functionBody: 'return await endReaderHintPreview();');
          if (started && restored?.value != true) {
            throw StateError('Could not restore the reading position');
          }
        }
      } finally {
        _hintPreviewActive = false;
      }
    }
  }
  bool _brightnessUiBlocked = true;

  void refreshBrightnessGesture() {
    if (mounted) setState(() {});
  }

  bool canGoBack = false;
  bool canGoForward = false;
  late Book book;
  String? backgroundColor;
  String? textColor;
  Timer? styleTimer;
  String bookmarkCfi = '';
  bool bookmarkExists = false;
  WritingModeEnum writingMode = WritingModeEnum.horizontalTb;
  String? _lastSelectionContextText;
  bool _selectionClearLocked = false;
  bool _selectionClearPending = false;
  ReaderEditHandlers? _readerEditHandlers;
  Map<String, dynamic>? _editReloadLocation;
  Completer<bool>? _editReloadCompletion;

  // Scroll wheel debounce
  Timer? _scrollDebounceTimer;
  double _accumulatedScrollDelta = 0;
  static const double _scrollThreshold = 50.0;

  // to know anytime if we are on top of navigation stack
  bool get _isTopOfNavigationStack =>
      ModalRoute.of(context)?.isCurrent ?? false;

  void prevPage() {
    webViewController.evaluateJavascript(source: 'prevPage()');
  }

  void nextPage() {
    webViewController.evaluateJavascript(source: 'nextPage()');
  }

  void prevChapter() {
    webViewController.evaluateJavascript(
      source: '''
      prevSection()
      ''',
    );
  }

  void nextChapter() {
    webViewController.evaluateJavascript(
      source: '''
      nextSection()
      ''',
    );
  }

  void setTranslationMode(TranslationModeEnum mode) {
    webViewController.evaluateJavascript(
      source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setTranslationMode) {
        reader.view.setTranslationMode('${mode.code}');
      }
      ''',
    );
  }

  Future<void> goToPercentage(double value) async {
    await webViewController.evaluateJavascript(
      source: '''
      goToPercent($value); 
      ''',
    );
  }

  void setSelectionClearLocked(bool locked) {
    _selectionClearLocked = locked;
    if (!locked && _selectionClearPending) {
      _selectionClearPending = false;
      _lastSelectionContextText = null;
      removeOverlay();
    }
  }

  void changeTheme(ReadTheme readTheme) {
    textColor = readTheme.textColor;
    backgroundColor = readTheme.backgroundColor;

    String bc = convertDartColorToJs(readTheme.backgroundColor);
    String tc = convertDartColorToJs(readTheme.textColor);

    webViewController.evaluateJavascript(
      source: '''
      changeStyle({
        backgroundColor: '#$bc',
        fontColor: '#$tc',
      })
      ''',
    );
  }

  void changeFootnoteAppearance(FootnoteAppearance appearance) {
    if (!mounted) return;
    webViewController.evaluateJavascript(
      source:
          'window.setFootnoteAppearance?.(${jsonEncode(appearance.toMap())});',
    );
  }

  void changeStyle(BookStyle? bookStyle) {
    styleTimer?.cancel();
    String bgimgUrl = Prefs().bgimg.getEffectiveUrl(
          isDarkMode: isDarkMode,
          autoAdjust: Prefs().autoAdjustReadingTheme,
        );

    styleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      BookStyle style = bookStyle ?? Prefs().bookStyle;
      webViewController.evaluateJavascript(
        source: '''
      changeStyle({
        fontSize: ${style.fontSize},
        footnoteAppearance: ${jsonEncode(Prefs().footnoteAppearance.toMap())},
        spacing: ${style.lineHeight},
        fontWeight: ${style.fontWeight},
        paragraphSpacing: ${style.paragraphSpacing},
        topMargin: ${style.topMargin},
        bottomMargin: ${style.bottomMargin},
        sideMargin: ${style.sideMargin},
        letterSpacing: ${style.letterSpacing},
        textIndent: ${style.indent},
        maxColumnCount: ${style.maxColumnCount},
        columnThreshold: ${style.columnThreshold},
        writingMode: '${Prefs().writingMode.code}',
        textAlign: '${Prefs().textAlignment.code}',
        backgroundImage: ${jsonEncode(bgimgUrl)},
        bgimgBlur: ${Prefs().bgimg.blur},
        bgimgOpacity: ${Prefs().bgimg.opacity},
        bgimgFit: '${Prefs().bgimgFit.code}',
        customCSS: ${jsonEncode(Prefs().customCSS)},
        customCSSEnabled: ${Prefs().customCSSEnabled},
        useBookStyles: ${Prefs().useBookStyles},
        headingFontSize: ${style.headingFontSize},
        codeHighlightTheme: '${Prefs().codeHighlightTheme.code}',
      })
      ''',
      );
    });
  }

  void changeBgimgEffect() {
    if (!mounted) return;
    final bgimg = Prefs().bgimg;
    final bgimgUrl = bgimg.getEffectiveUrl(
      isDarkMode: isDarkMode,
      autoAdjust: Prefs().autoAdjustReadingTheme,
    );
    webViewController.evaluateJavascript(
      source: '''
      changeStyle({
        backgroundImage: ${jsonEncode(bgimgUrl)},
        bgimgBlur: ${bgimg.blur},
        bgimgOpacity: ${bgimg.opacity},
        bgimgFit: '${Prefs().bgimgFit.code}',
      })
    ''',
    );
  }

  void changeReadingRules(ReadingRules readingRules) {
    webViewController.evaluateJavascript(
      source: '''
      readingFeatures({
        convertChineseMode: '${readingRules.convertChineseMode.name}',
        bionicReadingMode: ${readingRules.bionicReading},
      })
    ''',
    );
  }

  void changeFont(FontModel font) {
    webViewController.evaluateJavascript(
      source: '''
      changeStyle({
        fontName: ${jsonEncode(font.name)},
        fontPath: ${jsonEncode(font.path)},
      })
    ''',
    );
  }

  void changePageTurnStyle(PageTurn pageTurnStyle) {
    webViewController.evaluateJavascript(
      source: '''
      changeStyle({
        pageTurnStyle: '${pageTurnStyle.name}',
      })
    ''',
    );
  }

  void goToHref(String href) =>
      webViewController.evaluateJavascript(source: jsCall('goToHref', [href]));

  void goToCfi(String cfi) =>
      webViewController.evaluateJavascript(source: jsCall('goToCfi', [cfi]));

  void addAnnotation(BookNote bookNote) {
    webViewController.evaluateJavascript(
      source: jsCall('addAnnotation', [
        {
          'id': bookNote.id,
          'type': bookNote.type,
          'value': bookNote.cfi,
          'color': '#${bookNote.color}',
          'note': bookNote.content,
        },
      ]),
    );
  }

  void addBookmark(BookmarkModel bookmark) {
    webViewController.evaluateJavascript(
      source: jsCall('addAnnotation', [
        {
          'id': bookmark.id,
          'type': 'bookmark',
          'value': bookmark.cfi,
          'color': '#000000',
          'note': 'None',
        },
      ]),
    );
  }

  void addBookmarkHere() {
    webViewController.evaluateJavascript(
      source: '''
      addBookmarkHere()
      ''',
    );
  }

  void removeAnnotation(String cfi) => webViewController.evaluateJavascript(
        source: jsCall('removeAnnotation', [cfi]),
      );

  void clearSearch() {
    ref.read(tocSearchProvider.notifier).clear();
    _clearSearchHighlights();
  }

  void search(String text) {
    final sanitized = text.trim();
    if (sanitized.isEmpty) {
      clearSearch();
      return;
    }
    _clearSearchHighlights();
    ref.read(tocSearchProvider.notifier).start(sanitized);
    webViewController.evaluateJavascript(
      source: '''
      search(${jsonEncode(sanitized)}, {
        'scope': 'book',
        'matchCase': false,
        'matchDiacritics': false,
        'matchWholeWords': false,
      })
    ''',
    );
  }

  void _clearSearchHighlights() {
    webViewController.evaluateJavascript(source: "clearSearch()");
  }

  Future<void> initTts({String? fromCfi}) async {
    if (fromCfi != null && fromCfi.isNotEmpty) {
      await webViewController.evaluateJavascript(
        source: jsCall('window.ttsFromCfi', [fromCfi]),
      );
    } else {
      await webViewController.evaluateJavascript(source: "window.ttsHere()");
    }
  }

  void ttsStop() => webViewController.evaluateJavascript(source: "ttsStop()");

  Future<String> ttsNext() async =>
      (await webViewController.callAsyncJavaScript(
        functionBody: "return await ttsNext()",
      ))
          ?.value;

  Future<String> ttsPrev() async =>
      (await webViewController.callAsyncJavaScript(
        functionBody: "return await ttsPrev()",
      ))
          ?.value;

  Future<String> ttsPrevSection() async =>
      (await webViewController.callAsyncJavaScript(
        functionBody: "return await ttsPrevSection()",
      ))
          ?.value;

  Future<String> ttsNextSection() async =>
      (await webViewController.callAsyncJavaScript(
        functionBody: "return await ttsNextSection()",
      ))
          ?.value;

  Future<String> ttsPrepare() async =>
      (await webViewController.evaluateJavascript(source: "ttsPrepare()"));

  TtsSentence? _parseTtsSentence(dynamic value) {
    if (value is Map<dynamic, dynamic>) {
      try {
        return TtsSentence.fromMap(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  List<TtsSentence> _parseTtsSentences(dynamic value) {
    if (value is! List) return const [];

    final sentences = <TtsSentence>[];
    for (final item in value) {
      final sentence = _parseTtsSentence(item);
      if (sentence != null) {
        sentences.add(sentence);
      }
    }
    return sentences;
  }

  Future<TtsSentence?> ttsCurrentDetail() async {
    final result = await webViewController.callAsyncJavaScript(
      functionBody: 'return ttsCurrentDetail()',
    );
    return _parseTtsSentence(result?.value);
  }

  Future<List<TtsSentence>> ttsCollectDetails({
    required int count,
    bool includeCurrent = false,
    int offset = 1,
  }) async {
    final result = await webViewController.callAsyncJavaScript(
      functionBody:
          'return ttsCollectDetails($count, ${includeCurrent ? 'true' : 'false'}, $offset)',
    );
    return _parseTtsSentences(result?.value);
  }

  Future<void> ttsHighlightByCfi(String cfi) async {
    await webViewController.callAsyncJavaScript(
      functionBody: 'return ttsHighlightByCfi(${jsonEncode(cfi)})',
    );
  }

  Future<bool> isFootNoteOpen() async => (await webViewController
      .evaluateJavascript(source: "window.isFootNoteOpen()"));

  void backHistory() {
    webViewController.evaluateJavascript(source: "back()");
  }

  void forwardHistory() {
    webViewController.evaluateJavascript(source: "forward()");
  }

  void refreshToc() {
    webViewController.evaluateJavascript(source: "refreshToc()");
  }

  Future<String> theChapterContent() async =>
      await webViewController.evaluateJavascript(source: "theChapterContent()");

  Future<String> previousContent(int count) async => await webViewController
      .evaluateJavascript(source: "previousContent($count)");

  Future<String> _getCurrentChapterContent({int? maxCharacters}) async {
    final raw = await theChapterContent();
    return _normalizeChapterContent(raw, maxCharacters);
  }

  Future<String> _getChapterContentByHref(
    String href, {
    int? maxCharacters,
  }) async {
    if (href.isEmpty) {
      return '';
    }

    final result = await webViewController.callAsyncJavaScript(
      functionBody:
          'return await getChapterContentByHref("${href.replaceAll('"', '\\"')}")',
    );

    final value = result?.value;
    if (value is String) {
      return _normalizeChapterContent(value, maxCharacters);
    }
    return '';
  }

  String _normalizeChapterContent(String? content, int? maxCharacters) {
    if (content == null || content.isEmpty) {
      return '';
    }
    final trimmed = content.trim();
    if (maxCharacters != null &&
        maxCharacters > 0 &&
        trimmed.length > maxCharacters) {
      return trimmed.substring(0, maxCharacters);
    }
    return trimmed;
  }

  bool _editBookIsCurrent(int bookId) =>
      mounted &&
      widget.book.id == bookId &&
      ref.read(currentReadingProvider).isReading &&
      ref.read(currentReadingProvider).book?.id == bookId;

  Future<String?> _readerEditContext() async {
    final bookId = widget.book.id;
    final initialChapter =
        ref.read(currentReadingProvider).chapterHref ?? chapterHref;
    String chapterFile(String value) => value.split('#').first;
    if (!_editBookIsCurrent(bookId)) return null;
    try {
      final result = await webViewController.callAsyncJavaScript(
        functionBody: 'const viewport = $readerAssistantViewportScript; '
            'const anchor = await captureReaderEditLocation(); return {viewport, anchor};',
      );
      if (!_editBookIsCurrent(bookId) ||
          chapterFile(
                ref.read(currentReadingProvider).chapterHref ?? chapterHref,
              ) !=
              chapterFile(initialChapter)) return null;
      final bundle = result?.value;
      if (bundle is! Map) return null;
      final value = bundle['viewport'];
      final viewport = value is String ? jsonDecode(value) : value;
      if (viewport is! Map) return null;
      String bound(Object? value, int length) {
        final text = value?.toString() ?? '';
        return text.substring(0, text.length.clamp(0, length));
      }

      final anchor = bundle['anchor'];
      if (anchor is! Map ||
          chapterFile(anchor['chapterHref']?.toString() ?? '') !=
              chapterFile(initialChapter)) return null;
      return jsonEncode({
        'paragraphHash': anchor['paragraphHash'],
        'paragraphIndex': anchor['paragraphIndex'],
        'bookId': bookId,
        'title': bound(widget.book.title, 140),
        'chapterHref': bound(initialChapter, 500),
        'visible': bound(viewport['visible'], 6000),
        'selection': bound(viewport['selection'], 2000),
        'visibleTruncated': viewport['visibleTruncated'] == true,
        'selectionTruncated': viewport['selectionTruncated'] == true,
      });
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _applyReaderEdit(
    Map<String, dynamic> input,
    bool Function() requestIsCurrent,
  ) async {
    final bookId = widget.book.id;
    final file = File(widget.book.fileFullPath);
    final plan = ChatGptPlan.instance;
    final account = plan.active?.id;
    final revision = plan.requestRevision;
    final usesPlan = plan.enabled;
    final provider = Prefs().selectedAiService;
    bool current() =>
        requestIsCurrent() &&
        _editBookIsCurrent(bookId) &&
        plan.active?.id == account &&
        plan.requestRevision == revision &&
        plan.enabled == usesPlan &&
        Prefs().selectedAiService == provider;
    if (!current())
      throw const EpubEditException(
        'The book or account changed. Nothing was saved.',
      );
    final requested = input['chapterHref'];
    final href = requested is String && requested.isNotEmpty
        ? requested
        : ref.read(currentReadingProvider).chapterHref ?? chapterHref;
    if (href.isEmpty)
      throw const EpubEditException('The current chapter is not known yet.');
    if (file.path.toLowerCase().endsWith('.pdf')) {
      return _applyPdfReaderEdit(file, href, input, current);
    }
    final store = EpubEditStore();
    final snapshot = await store.readChapter(file: file, chapterHref: href);
    if (!current())
      throw const EpubEditException(
        'The book or account changed. Nothing was saved.',
      );
    final spec = Map<String, dynamic>.from(input)..remove('chapterHref');
    final prepared = await webViewController.callAsyncJavaScript(
      functionBody: 'return await ${jsCall('prepareEpubEdit', [
            snapshot.xhtml,
            spec,
            snapshot.bookIdentifier
          ])};',
    );
    if (!current())
      throw const EpubEditException(
        'The book or account changed. Nothing was saved.',
      );
    final raw = prepared?.value;
    if (raw is! Map)
      throw const EpubEditException('Could not verify the exact phrase.');
    final edit = Map<String, dynamic>.from(raw);
    if (edit['editError'] != null) {
      final message = switch (edit['editError']) {
        'ambiguous' =>
          'Multiple exact matches found. Specify context or occurrence; nothing was saved.',
        'not_found' => 'Exact phrase and context not found. Nothing was saved.',
        'ruby_overlap' =>
          'This word already has a ruby hint. Nested hints are not supported.',
        'word_markup' =>
          'Internal markup splits this word. Choose a neighboring unsplit word.',
        'operation_collision' =>
          'This operationId was already saved with different content.',
        'missing_context' =>
          'Provide an exact phrase and surrounding context or a verified paragraphHash.',
        'occurrence_missing' => 'The specified occurrence does not exist.',
        'legacy_overlap' =>
          'Overlapping legacy highlights cannot be distinguished safely. Nothing was saved.',
        'invalid_metadata' =>
          'Saved annotation metadata is invalid. Nothing was saved.',
        'invalid_xhtml' =>
          'Chapter XHTML validation failed. Nothing was saved.',
        _ => 'Annotation validation failed. Nothing was saved.',
      };
      throw EpubEditException(message);
    }
    return _savePreparedReaderEdit(
        store: store,
        snapshot: snapshot,
        edit: edit,
        spec: spec,
        href: href,
        current: current);
  }

  Future<void> _loadPdfHints() async {
    if (!widget.book.fileFullPath.toLowerCase().endsWith('.pdf')) return;
    final bookId = widget.book.id;
    try {
      final snapshot =
          await PdfHintStore().read(File(widget.book.fileFullPath));
      if (!_editBookIsCurrent(bookId)) return;
      await webViewController.callAsyncJavaScript(
        functionBody:
            'return await ${jsCall('setPdfHintPages', [snapshot.pages])};',
      );
    } catch (_) {
      if (mounted)
        AnxToast.show(
            'Saved PDF hints could not be loaded. The notes are preserved.');
    }
  }

  Future<Map<String, dynamic>> _applyPdfReaderEdit(File file, String href,
      Map<String, dynamic> input, bool Function() current) async {
    bool samePage() =>
        current() &&
        (ref.read(currentReadingProvider).chapterHref ?? chapterHref) == href;
    if (!samePage())
      throw const EpubEditException('The PDF page changed. Nothing was saved.');
    final store = PdfHintStore();
    final snapshot = await store.read(file);
    if (!samePage())
      throw const EpubEditException('The PDF page changed. Nothing was saved.');
    final spec = Map<String, dynamic>.from(input)..remove('chapterHref');
    final prepared = await webViewController.callAsyncJavaScript(
      functionBody: 'return await ${jsCall('preparePdfEdits', [
            spec,
            snapshot.pages[href] ?? [],
            href
          ])};',
    );
    if (!samePage())
      throw const EpubEditException('The PDF page changed. Nothing was saved.');
    final raw = prepared?.value;
    if (raw is! Map)
      throw const EpubEditException('Could not verify the PDF text.');
    if (raw['editError'] != null)
      throw EpubEditException('${raw['editError']}');
    final changed = raw['changed'] == true;
    var displayed = true;
    if (changed) {
      if (raw['records'] is! List)
        throw const EpubEditException('Invalid PDF annotation result.');
      final pages = <String, dynamic>{...snapshot.pages, href: raw['records']};
      await store.commit(snapshot: snapshot, pages: pages, isCurrent: samePage);
      try {
        if (current()) {
          final result = await webViewController.callAsyncJavaScript(
            functionBody: 'return await ${jsCall('setPdfHintPages', [pages])};',
          );
          displayed = result?.value == true;
        } else {
          displayed = false;
        }
      } catch (_) {
        displayed = false;
      }
    }
    return {
      'changed': changed,
      'chapterHref': href,
      'items': raw['items'],
      'activeCount': raw['activeCount'],
      'storage': 'Anx PDF sidecar; original PDF bytes unchanged',
      'displayed': displayed,
      if (!displayed)
        'message': 'Saved. Reopen the PDF to display the annotations.'
    };
  }

  Future<Map<String, dynamic>> _savePreparedReaderEdit({
    required EpubEditStore store,
    required EpubChapterSnapshot snapshot,
    required Map<String, dynamic> edit,
    required Map<String, dynamic> spec,
    required String href,
    required bool Function() current,
    List<EpubImageAsset> images = const [],
  }) async {
    final file = snapshot.file;
    final bookId = widget.book.id;
    if (edit['unchanged'] == true) {
      return {
        'changed': false,
        'operationId': edit['operationId'] ?? spec['operationId'],
        'chapterHref': href,
        'anchor': edit['anchor'],
        if (edit['items'] is List) 'items': edit['items'],
      };
    }
    if (edit['xhtml'] is! String)
      throw const EpubEditException(
        'XHTML validation did not return an updated chapter.',
      );
    // Verify we can preserve the reading location before performing any write.
    final locationResult = await webViewController.callAsyncJavaScript(
      functionBody: 'return await captureReaderEditLocation();',
    );
    if (locationResult?.value is! Map)
      throw const EpubEditException(
        'Could not preserve the reading position. Nothing was saved.',
      );
    var location = Map<String, dynamic>.from(locationResult!.value as Map);
    if (!current())
      throw const EpubEditException(
        'The book or account changed. Nothing was saved.',
      );
    final result = await store.commit(
      snapshot: snapshot,
      xhtml: edit['xhtml'] as String,
      isCurrent: current,
      images: images,
    );
    if (!result.changed)
      return {
        'changed': false,
        'operationId': edit['operationId'] ?? spec['operationId'],
        'chapterHref': href,
        'anchor': edit['anchor'],
        if (edit['items'] is List) 'items': edit['items'],
      };
    var restored = false;
    Completer<bool>? ownedCompletion;
    try {
      await BookContentSearchRepository.invalidateBook(bookId);
    } catch (_) {
      /* saved already */
    }
    try {
      if (current()) {
        // Capture again after I/O so reading while the tool worked does not jump
        // back to the request's earlier viewport. Original Spanish is unchanged.
        try {
          final latest = await webViewController.callAsyncJavaScript(
            functionBody: 'return await captureReaderEditLocation();',
          );
          if (latest?.value is Map)
            location = Map<String, dynamic>.from(latest!.value as Map);
        } catch (_) {
          /* use the verified pre-write snapshot */
        }
        if (current()) {
          final completion = Completer<bool>();
          ownedCompletion = completion;
          _editReloadLocation = {...location, 'bookId': bookId};
          _editReloadCompletion = completion;
          final uri = Uri.encodeComponent(file.path);
          final url =
              '${Server().baseUrl}/book/$uri?edit=${DateTime.now().microsecondsSinceEpoch}';
          await webViewController.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(
                generateUrl(
                  url,
                  location['baseCfi'] as String,
                  hintFilter: ReaderHintFilter.fromJson(Prefs()
                          .prefs
                          .getString('readerHintFilter:${widget.book.id}'))
                      .toRules(),
                  backgroundColor: backgroundColor,
                  textColor: textColor,
                  isDarkMode: Theme.of(context).brightness == Brightness.dark,
                ),
              ),
            ),
          );
          restored = await completion.future.timeout(
            const Duration(seconds: 12),
            onTimeout: () => false,
          );
          if (identical(_editReloadCompletion, completion)) {
            _editReloadCompletion = null;
            _editReloadLocation = null;
          }
        }
      }
    } catch (_) {
      // Commit already succeeded. Never report a reload failure as a failed write.
      final pending = ownedCompletion;
      if (pending != null && !pending.isCompleted) pending.complete(false);
      if (identical(_editReloadCompletion, pending)) {
        _editReloadCompletion = null;
        _editReloadLocation = null;
      }
    }
    return {
      'changed': true,
      'operationId': edit['operationId'] ?? spec['operationId'],
      'chapterHref': href,
      'anchor': edit['anchor'],
      if (edit['items'] is List) 'items': edit['items'],
      'locationRestored': restored,
      if (!restored)
        'message':
            'Annotation saved to EPUB. Please check your reading position.',
    };
  }

  Future<Map<String, dynamic>> readerImageOperation(Map<String, dynamic> input,
      [bool Function()? requestIsCurrent]) async {
    final plan = ChatGptPlan.instance;
    final account = plan.active?.id;
    final revision = plan.requestRevision;
    final usesPlan = plan.enabled;
    final provider = Prefs().selectedAiService;
    final bookId = widget.book.id;
    bool current() =>
        (requestIsCurrent?.call() ?? true) &&
        _editBookIsCurrent(bookId) &&
        plan.active?.id == account &&
        plan.requestRevision == revision &&
        plan.enabled == usesPlan &&
        Prefs().selectedAiService == provider;
    final href = input['chapterHref'] as String? ??
        ref.read(currentReadingProvider).chapterHref ??
        chapterHref;
    if (!current() || href.isEmpty)
      throw const EpubEditException(
          'Open a book chapter before using image tools.');
    final handler = ReaderBookImages(
      file: File(widget.book.fileFullPath),
      chapterHref: href,
      vault: BookImageVault('$bookId:$account:$provider'),
      current: current,
      generate: (prompt, beforeSend) =>
          generateBookIllustration(prompt, beforeSend: beforeSend),
      visibleIndices: () async {
        if ((ref.read(currentReadingProvider).chapterHref ?? chapterHref)
                .split('#')
                .first !=
            href.split('#').first) return [];
        final result = await webViewController.callAsyncJavaScript(
            functionBody: 'return visibleBookImageIndices();');
        return result?.value is List
            ? (result!.value as List).whereType<int>().toList()
            : [];
      },
      prepareInsertion: (source, spec) async {
        final result = await webViewController.callAsyncJavaScript(
            functionBody: 'return await ${jsCall('prepareBookImageInsertion', [
              source,
              spec
            ])};');
        if (result?.value is! Map)
          throw const EpubEditException(
              'Could not anchor the illustration. No book changes were saved.');
        return Map<String, dynamic>.from(result!.value as Map);
      },
      save: (snapshot, edit, images) => _savePreparedReaderEdit(
          store: EpubEditStore(),
          snapshot: snapshot,
          edit: edit,
          spec: input,
          href: href,
          current: current,
          images: images),
    );
    return handler.handle(input);
  }

  Future<void> _restoreReaderEditAfterLoad() async {
    final location = _editReloadLocation;
    final completion = _editReloadCompletion;
    if (location == null || completion == null || completion.isCompleted)
      return;
    if (!_editBookIsCurrent(location['bookId'] as int)) {
      completion.complete(false);
      return;
    }
    try {
      final result = await webViewController.callAsyncJavaScript(
        functionBody:
            'return await ${jsCall('restoreReaderEditLocation', [location])};',
      );
      if (!completion.isCompleted)
        completion.complete(
          result?.value is Map && (result!.value as Map)['restored'] == true,
        );
    } catch (_) {
      if (!completion.isCompleted) completion.complete(false);
    }
  }

  void _registerReaderEditBridge() {
    if (_readerEditHandlers?.bookId != widget.book.id) {
      _readerEditHandlers = ReaderEditHandlers(
        bookId: widget.book.id,
        apply: _applyReaderEdit,
        context: _readerEditContext,
        images: (input, current) => readerImageOperation(input, current),
      );
    }
    ref.read(readerEditBridgeProvider.notifier).state = _readerEditHandlers;
  }

  void _registerChapterContentBridge() {
    ref.read(chapterContentBridgeProvider.notifier).state =
        ChapterContentHandlers(
      fetchCurrentChapter: ({int? maxCharacters}) =>
          _getCurrentChapterContent(maxCharacters: maxCharacters),
      fetchChapterByHref: (href, {int? maxCharacters}) =>
          _getChapterContentByHref(href, maxCharacters: maxCharacters),
    );
  }

  Future<void> _handleExternalLink(dynamic rawLink) async {
    String? normalizeExternalLink(dynamic raw) {
      if (raw == null) {
        return null;
      }
      if (raw is String && raw.trim().isNotEmpty) {
        return raw.trim();
      }
      if (raw is Map && raw['href'] is String) {
        final href = raw['href'].toString().trim();
        return href.isEmpty ? null : href;
      }
      return null;
    }

    final link = normalizeExternalLink(rawLink);
    if (!mounted || link == null) {
      return;
    }

    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme.isEmpty || uri.scheme == 'javascript') {
      AnxLog.warning('Ignored invalid external link: $link');
      return;
    }

    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = L10n.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.readingPageOpenExternalLinkTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.readingPageOpenExternalLinkMessage),
              const SizedBox(height: 8),
              SelectableText(link),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.readingPageOpenExternalLinkAction),
            ),
          ],
        );
      },
    );

    if (shouldOpen != true) {
      return;
    }

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      AnxLog.warning('Failed to open external link: $link');
    }
  }

  void onClick(Map<String, dynamic> location) {
    readingPageKey.currentState?.resetAwakeTimer();
    if (contextMenuEntry != null) {
      removeOverlay();
      return;
    }
    final x = location['x'];
    final y = location['y'];
    final part = coordinatesToPart(x, y);

    PageTurningType action;
    final pageTurnMode = PageTurnMode.fromCode(Prefs().pageTurnMode);

    if (pageTurnMode == PageTurnMode.simple) {
      // Use predefined page turning types
      final currentPageTurningType = Prefs().pageTurningType;
      final pageTurningType = pageTurningTypes[currentPageTurningType];
      action = pageTurningType[part];

      // Apply swap if enabled
      if (Prefs().swapPageTurnArea) {
        if (action == PageTurningType.prev) {
          action = PageTurningType.next;
        } else if (action == PageTurningType.next) {
          action = PageTurningType.prev;
        }
      }
    } else {
      // Use custom configuration
      final customConfig = Prefs().customPageTurnConfig;
      action = PageTurningType.values[customConfig[part]];
    }

    // Disable mouse/touch page turning when keyboard shortcuts are enabled
    if (Prefs().keyboardShortcutTurnPage) {
      // Only allow menu action, disable prev/next page turning
      if (action == PageTurningType.prev || action == PageTurningType.next) {
        return;
      }
    }

    switch (action) {
      case PageTurningType.prev:
        prevPage();
        break;
      case PageTurningType.next:
        nextPage();
        break;
      case PageTurningType.menu:
        widget.showOrHideAppBarAndBottomBar(true);
        break;
      case PageTurningType.none:
        break;
    }
  }

  Future<void> renderAnnotations(InAppWebViewController controller) async {
    List<BookNote> annotationList = await bookNoteDao.selectBookNotesByBookId(
      widget.book.id,
    );
    String allAnnotations = jsonEncode(
      annotationList.map((e) => e.toJson()).toList(),
    );
    controller.evaluateJavascript(
      source: '''
     const allAnnotations = $allAnnotations
     renderAnnotations()
    ''',
    );
  }

  void getThemeColor() {
    if (Prefs().autoAdjustReadingTheme) {
      List<ReadTheme> themes = widget.initialThemes;
      final isDayMode =
          Theme.of(navigatorKey.currentContext!).brightness == Brightness.light;
      backgroundColor =
          isDayMode ? themes[0].backgroundColor : themes[1].backgroundColor;
      textColor = isDayMode ? themes[0].textColor : themes[1].textColor;
    } else {
      backgroundColor = Prefs().readTheme.backgroundColor;
      textColor = Prefs().readTheme.textColor;
    }
  }

  Future<void> setHandler(InAppWebViewController controller) async {
    controller.addJavaScriptHandler(
      handlerName: 'onReaderBrightnessUiState',
      callback: (args) {
        _brightnessUiBlocked = args.isEmpty ||
            args.first is! Map ||
            args.first['blocked'] != false;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onLoadEnd',
      callback: (args) async {
        await _restoreReaderEditAfterLoad();
        await _loadPdfHints();
        widget.onLoadEnd();
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onRelocated',
      callback: (args) {
        if (_hintPreviewActive) return;
        Map<String, dynamic> location = args[0];
        if (cfi == location['cfi']) return;
        // if (chapterHref != location['chapterHref']) {
        //   refreshToc();
        // }
        setState(() {
          cfi = location['cfi'] ?? '';
          percentage =
              double.tryParse(location['percentage'].toString()) ?? 0.0;
          chapterTitle = location['chapterTitle'] ?? '';
          chapterHref = location['chapterHref'] ?? '';
          chapterCurrentPage = location['chapterCurrentPage'] ?? 0;
          chapterTotalPages = location['chapterTotalPages'] ?? 0;
          bookmarkExists = location['bookmark']['exists'] ?? false;
          bookmarkCfi = location['bookmark']['cfi'] ?? '';
          writingMode = WritingModeEnum.fromCode(location['writingMode'] ?? '');
        });
        ref.read(currentReadingProvider.notifier).update(
              cfi: cfi,
              percentage: percentage,
              chapterTitle: chapterTitle,
              chapterHref: chapterHref,
              chapterCurrentPage: chapterCurrentPage,
              chapterTotalPages: chapterTotalPages,
            );
        widget.updateParent();
        saveReadingProgress();
        readingPageKey.currentState?.resetAwakeTimer();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onClick',
      callback: (args) {
        Map<String, dynamic> location = args[0];
        onClick(location);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onExternalLink',
      callback: (args) async {
        final payload = args.isNotEmpty ? args.first : null;
        await _handleExternalLink(payload);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onSetToc',
      callback: (args) {
        List<dynamic> t = args[0];
        final toc = t.map((i) => TocItem.fromJson(i)).toList();
        ref.read(bookTocProvider.notifier).setToc(toc);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onSelectionEnd',
      callback: (args) {
        removeOverlay();
        Map<String, dynamic> location = args[0];
        String cfi = location['cfi'];
        String text = location['text'];
        bool footnote = location['footnote'];
        final rawContextText = location['contextText']?.toString();
        _lastSelectionContextText =
            (rawContextText?.trim().isEmpty ?? true) ? null : rawContextText;
        double left = (location['pos']['left'] as num).toDouble();
        double top = (location['pos']['top'] as num).toDouble();
        double right = (location['pos']['right'] as num).toDouble();
        double bottom = (location['pos']['bottom'] as num).toDouble();
        showContextMenu(
          context,
          left,
          top,
          right,
          bottom,
          text,
          cfi,
          null,
          footnote,
          writingMode.isVertical ? Axis.vertical : Axis.horizontal,
          contextText: _lastSelectionContextText,
        );
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onSelectionCleared',
      callback: (args) {
        if (_selectionClearLocked) {
          _selectionClearPending = true;
          return;
        }
        _lastSelectionContextText = null;
        removeOverlay();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onAnnotationClick',
      callback: (args) {
        Map<String, dynamic> annotation = args[0];

        if (annotation['annotation'] == null) {
          // Check if TTS is active and the click is on the currently read text
          final currentTtsState = TtsHandler().ttsStateNotifier.value;
          if (currentTtsState == TtsStateEnum.playing ||
              currentTtsState == TtsStateEnum.paused) {
            if (currentTtsState == TtsStateEnum.playing) {
              audioHandler.pause();
            } else {
              audioHandler.play();
            }
            return;
          }
        }

        int id = annotation['annotation']['id'];
        String cfi = annotation['annotation']['value'];
        String note = annotation['annotation']['note'];
        final rawContextText = annotation['contextText']?.toString();
        _lastSelectionContextText =
            (rawContextText?.trim().isEmpty ?? true) ? null : rawContextText;
        double left = (annotation['pos']['left'] as num).toDouble();
        double top = (annotation['pos']['top'] as num).toDouble();
        double right = (annotation['pos']['right'] as num).toDouble();
        double bottom = (annotation['pos']['bottom'] as num).toDouble();
        showContextMenu(
          context,
          left,
          top,
          right,
          bottom,
          note,
          cfi,
          id,
          false,
          writingMode.isVertical ? Axis.vertical : Axis.horizontal,
          contextText: _lastSelectionContextText,
        );
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onSearch',
      callback: (args) {
        Map<String, dynamic> search = args[0];
        setState(() {
          final tocSearch = ref.read(tocSearchProvider.notifier);
          if (search['process'] != null) {
            final progress = search['process'].toDouble();
            tocSearch.updateProgress(progress);
          } else {
            tocSearch.addResult(SearchResultModel.fromJson(search));
          }
        });
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'renderAnnotations',
      callback: (args) {
        renderAnnotations(controller);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onPushState',
      callback: (args) {
        Map<String, dynamic> state = args[0];
        if (!mounted) return;
        setState(() {
          canGoBack = state['canGoBack'];
          canGoForward = state['canGoForward'];
          showHistory = canGoBack || canGoForward;
        });
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onImageClick',
      callback: (args) {
        String image = args[0];
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                ImageViewer(image: image, bookName: widget.book.title),
          ),
        );
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onFootnoteClose',
      callback: (args) {
        removeOverlay();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onPullUp',
      callback: (args) {
        widget.showOrHideAppBarAndBottomBar(true);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'handleBookmark',
      callback: (args) async {
        Map<String, dynamic> detail = args[0]['detail'];
        bool remove = args[0]['remove'];
        String cfi = detail['cfi'] ?? '';
        double percentage = double.parse(detail['percentage'].toString());
        String content = detail['content'];

        if (remove) {
          ref
              .read(bookmarkProvider(widget.book.id).notifier)
              .removeBookmark(cfi: cfi);
          bookmarkCfi = '';
          bookmarkExists = false;
        } else {
          BookmarkModel bookmark = await ref
              .read(BookmarkProvider(widget.book.id).notifier)
              .addBookmark(
                BookmarkModel(
                  bookId: widget.book.id,
                  cfi: cfi,
                  percentage: percentage,
                  content: content,
                  chapter: chapterTitle,
                  updateTime: DateTime.now(),
                  createTime: DateTime.now(),
                ),
              );
          bookmarkCfi = cfi;
          bookmarkExists = true;
          addBookmark(bookmark);
        }
        widget.updateParent();
        setState(() {});
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'translateText',
      callback: (args) async {
        try {
          String text = args[0];
          final service = Prefs().fullTextTranslateService;
          final from = Prefs().fullTextTranslateFrom;
          final to = Prefs().fullTextTranslateTo;

          return await service.provider.translateTextOnly(
            text,
            from,
            to,
            isFullText: true,
          );
        } catch (e) {
          AnxLog.severe('Translation error: $e');
          return 'Translation error: $e';
        }
      },
    );
  }

  Future<void> onWebViewCreated(InAppWebViewController controller) async {
    if (AnxPlatform.isAndroid) {
      await InAppWebViewController.setWebContentsDebuggingEnabled(kDebugMode);
    }
    webViewController = controller;
    setHandler(controller);
    _brightnessUiBlocked = true;
    await controller.evaluateJavascript(source: readerBrightnessGateScript);
    _registerChapterContentBridge();
    _registerReaderEditBridge();

    // Initialize translation mode based on book-specific settings
    Future.delayed(const Duration(milliseconds: 300), () {
      setTranslationMode(Prefs().getBookTranslationMode(widget.book.id));
    });
  }

  void removeOverlay() {
    _selectionClearLocked = false;
    _selectionClearPending = false;
    if (contextMenuEntry == null || contextMenuEntry?.mounted == false) return;
    contextMenuEntry?.remove();
    contextMenuEntry = null;
  }

  Future<void> _handlePointerEvents(PointerEvent event) async {
    if (await isFootNoteOpen() || Prefs().pageTurnStyle == PageTurn.scroll) {
      return;
    }
    // Disable scroll wheel page turning when keyboard shortcuts are enabled
    if (Prefs().keyboardShortcutTurnPage) {
      return;
    }
    if (event is PointerScrollEvent) {
      _accumulatedScrollDelta += event.scrollDelta.dy;

      _scrollDebounceTimer?.cancel();
      _scrollDebounceTimer = Timer(const Duration(milliseconds: 80), () {
        if (_accumulatedScrollDelta.abs() >= _scrollThreshold) {
          if (_accumulatedScrollDelta > 0) {
            nextPage();
          } else {
            prevPage();
          }
        }
        _accumulatedScrollDelta = 0;
      });
    }
  }

  @override
  void initState() {
    book = widget.book;
    getThemeColor();

    contextMenu = ContextMenu(
      settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
      onCreateContextMenu: (hitTestResult) async {
        // webViewController.evaluateJavascript(source: "showContextMenu()");
      },
      onHideContextMenu: () {
        // removeOverlay();
      },
    );
    if (Prefs().openBookAnimation) {
      _animationController = AnimationController(
        duration: const Duration(milliseconds: 600),
        vsync: this,
      );
      _animation = Tween<double>(
        begin: 1.0,
        end: 0.0,
      ).animate(_animationController!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _animationController!.forward();
      });
    }
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  Future<void> saveReadingProgress() async {
    if (cfi == '' || widget.cfi != null) return;
    Book book = widget.book;
    book.lastReadPosition = cfi;
    book.readingPercentage = percentage;
    await bookDao.updateBook(book);
    if (mounted) {
      ref.read(bookListProvider.notifier).refresh();
    }
  }

  @override
  void dispose() {
    final completion = _editReloadCompletion;
    if (completion != null && !completion.isCompleted)
      completion.complete(false);
    final handlers = _readerEditHandlers;
    final container = ProviderScope.containerOf(context, listen: false);
    Future.microtask(() {
      try {
        if (identical(container.read(readerEditBridgeProvider), handlers)) {
          container.read(readerEditBridgeProvider.notifier).state = null;
        }
      } catch (_) {
        /* the whole ProviderScope may already be disposed */
      }
    });
    _scrollDebounceTimer?.cancel();
    _animationController?.dispose();
    saveReadingProgress();
    removeOverlay();
    super.dispose();
  }

  InAppWebViewSettings initialSettings = InAppWebViewSettings(
    supportZoom: false,
    transparentBackground: true,
    isInspectable: kDebugMode,
    useHybridComposition: true,
  );

  bool get isDarkMode =>
      Theme.of(navigatorKey.currentContext!).brightness == Brightness.dark;

  void changeReadingInfo() {
    setState(() {});
  }

  Widget _buildHistoryCapsule() {
    final l10n = L10n.of(context);
    final buttonColor = Color(int.parse('0x$textColor')).withAlpha(200);

    // Common button style for all history navigation buttons
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
    );

    // Helper method to create history navigation buttons
    Widget createHistoryButton(
      IconData icon,
      String label,
      VoidCallback onPressed,
    ) {
      return TextButton.icon(
        icon: Icon(icon, size: 18, color: buttonColor),
        label: Text(label, style: TextStyle(color: buttonColor, fontSize: 14)),
        onPressed: onPressed,
        style: buttonStyle,
      );
    }

    // Build buttons list
    final List<Widget> buttons = [];

    if (canGoBack) {
      buttons.add(
        createHistoryButton(Icons.arrow_back, l10n.historyBack, backHistory),
      );
    }

    buttons.add(
      createHistoryButton(
        Icons.close,
        l10n.historyClose,
        () => setState(() => showHistory = false),
      ),
    );

    if (canGoForward) {
      buttons.add(
        createHistoryButton(
          Icons.arrow_forward,
          l10n.historyForward,
          forwardHistory,
        ),
      );
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainer.withAlpha(123),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 0.5,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
            ),
          ),
        ),
      ),
    );
  }

  Widget readingInfoWidget() {
    if (chapterCurrentPage == 0 && percentage == 0.0) {
      return const SizedBox();
    }

    final readingInfoColor = Color(int.parse('0x$textColor')).withAlpha(150);
    final iconColor = Color(int.parse('0x$textColor'));

    Widget getWidget(ReadingInfoEnum readingInfoEnum, TextStyle textStyle) {
      final batteryTextStyle = TextStyle(
        color: iconColor,
        fontSize: (textStyle.fontSize ?? 10) - 1,
      );
      final batteryIconSize = (textStyle.fontSize ?? 10) * 2.7;

      final chapterTitleWidget = Text(
        (chapterCurrentPage == 1 ? widget.book.title : chapterTitle),
        style: textStyle,
      );

      final chapterProgressWidget = Text(
        '$chapterCurrentPage/$chapterTotalPages',
        style: textStyle,
      );

      final bookProgressWidget = Text(
        '${(percentage * 100).toStringAsFixed(2)}%',
        style: textStyle,
      );

      final timeWidget = MinuteClock(textStyle: textStyle);

      final batteryWidget = FutureBuilder(
        future: Battery().batteryLevel,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    0,
                    (textStyle.fontSize ?? 10) * 0.08,
                    2,
                    0,
                  ),
                  child: Text('${snapshot.data}', style: batteryTextStyle),
                ),
                Icon(
                  HeroIcons.battery_0,
                  size: batteryIconSize,
                  color: iconColor,
                ),
              ],
            );
          } else {
            return const SizedBox();
          }
        },
      );

      Widget batteryAndTimeWidget() => Row(
            mainAxisSize: MainAxisSize.min,
            children: [batteryWidget, const SizedBox(width: 5), timeWidget],
          );

      switch (readingInfoEnum) {
        case ReadingInfoEnum.chapterTitle:
          return chapterTitleWidget;
        case ReadingInfoEnum.chapterProgress:
          return chapterProgressWidget;
        case ReadingInfoEnum.bookProgress:
          return bookProgressWidget;
        case ReadingInfoEnum.battery:
          return batteryWidget;
        case ReadingInfoEnum.time:
          return timeWidget;
        case ReadingInfoEnum.batteryAndTime:
          return batteryAndTimeWidget();
        case ReadingInfoEnum.none:
          return const SizedBox(width: 30);
      }
    }

    final readingInfo = Prefs().readingInfo;

    final headerTextStyle = TextStyle(
      color: readingInfoColor,
      fontSize: readingInfo.header.fontSize,
    );
    final footerTextStyle = TextStyle(
      color: readingInfoColor,
      fontSize: readingInfo.footer.fontSize,
    );

    List<Widget> headerWidgets = [
      getWidget(readingInfo.header.left, headerTextStyle),
      getWidget(readingInfo.header.center, headerTextStyle),
      getWidget(readingInfo.header.right, headerTextStyle),
    ];

    List<Widget> footerWidgets = [
      getWidget(readingInfo.footer.left, footerTextStyle),
      getWidget(readingInfo.footer.center, footerTextStyle),
      getWidget(readingInfo.footer.right, footerTextStyle),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            top: readingInfo.header.verticalMargin,
            left: readingInfo.header.leftMargin,
            right: readingInfo.header.rightMargin,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: headerWidgets,
          ),
        ),
        const Spacer(),
        Padding(
          padding: EdgeInsets.only(
            bottom: readingInfo.footer.verticalMargin,
            left: readingInfo.footer.leftMargin,
            right: readingInfo.footer.rightMargin,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: footerWidgets,
          ),
        ),
      ],
    );
  }

  Widget buildWebviewWithIOSWorkaround(
    BuildContext context,
    String url,
    String initialCfi,
  ) {
    final webView = InAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialUrlRequest: URLRequest(
        url: WebUri(
          generateUrl(
            url,
            initialCfi,
            hintFilter: ReaderHintFilter.fromJson(Prefs()
                    .prefs
                    .getString('readerHintFilter:${widget.book.id}'))
                .toRules(),
            backgroundColor: backgroundColor,
            textColor: textColor,
            isDarkMode: Theme.of(context).brightness == Brightness.dark,
          ),
        ),
      ),
      initialSettings: initialSettings,
      contextMenu: contextMenu,
      onLoadStop: (controller, uri) => onWebViewCreated(controller),
      onConsoleMessage: webviewConsoleMessage,
    );

    if (!AnxPlatform.isIOS) {
      return SizedBox.expand(
        child: ReaderBrightnessGesture(
          enabled: Prefs().readerBrightnessGesture,
          canStart: () =>
              _isTopOfNavigationStack &&
              !_brightnessUiBlocked &&
              contextMenuEntry == null &&
              (readingPageKey.currentState?.bottomBarOffstage ?? true),
          child: webView,
        ),
      );
    }

    return SizedBox.expand(
      child: Stack(
        children: [
          webView,
          Positioned.fill(
            child: PointerInterceptor(
              intercepting: !_isTopOfNavigationStack,
              debug: false,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String uri = Uri.encodeComponent(widget.book.fileFullPath);
    String url = '${Server().baseUrl}/book/$uri';
    String initialCfi = widget.cfi ?? widget.book.lastReadPosition;

    return Listener(
      onPointerSignal: (event) {
        _handlePointerEvents(event);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            buildWebviewWithIOSWorkaround(context, url, initialCfi),
            readingInfoWidget(),
            if (showHistory) _buildHistoryCapsule(),
            if (Prefs().openBookAnimation)
              SizedBox.expand(
                child: IgnorePointer(
                  ignoring: true,
                  child: FadeTransition(
                    opacity: _animation!,
                    child: BookCover(book: widget.book),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
