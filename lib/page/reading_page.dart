import 'package:anx_reader/models/reader_hint_filter.dart';
import 'package:anx_reader/widgets/ai/reader_hint_settings.dart';
import 'package:anx_reader/widgets/ai/book_illustrations_sheet.dart';
import 'dart:convert';
import 'package:anx_reader/utils/js/js_call.dart';
import 'dart:async';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/providers/ai_providers.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:anx_reader/service/voice/assistant_session.dart';
import 'package:anx_reader/service/voice/book_assistant_turn.dart';
import 'package:anx_reader/service/voice/reader_assistant_context.dart';
import 'package:anx_reader/widgets/ai/floating_book_assistant.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:langchain_core/chat_models.dart';
import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/dao/theme.dart';
import 'package:anx_reader/enums/ai_panel_position.dart';
import 'package:anx_reader/enums/ai_chat_display_mode.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/ai_quick_prompt_chip.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/page/book_detail.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/utils/ui/status_bar.dart';
import 'package:anx_reader/widgets/ai/ai_chat_stream.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:anx_reader/widgets/reading_page/notes_widget.dart';
import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/widgets/reading_page/progress_widget.dart';
import 'package:anx_reader/widgets/reading_page/tts_fab.dart';
import 'package:anx_reader/widgets/reading_page/tts_widget.dart';
import 'package:anx_reader/widgets/reading_page/style_widget.dart';
import 'package:anx_reader/widgets/reading_page/toc_widget.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// import 'package:flutter/foundation.dart'
// show debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ReadingPage extends ConsumerStatefulWidget {
  const ReadingPage({
    super.key,
    required this.book,
    this.cfi,
    required this.initialThemes,
    this.heroTag,
  });

  final Book book;
  final String? cfi;
  final List<ReadTheme> initialThemes;
  final String? heroTag;

  @override
  ConsumerState<ReadingPage> createState() => ReadingPageState();
}

final GlobalKey<ReadingPageState> readingPageKey =
    GlobalKey<ReadingPageState>();
final epubPlayerKey = GlobalKey<EpubPlayerState>();

class ReadingPageState extends ConsumerState<ReadingPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const empty = SizedBox.shrink();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late Book _book;
  late Widget _currentPage = empty;
  String? _aiSelectedText;
  String? _selectionCfi;
  late final BookAssistantTurn _assistantTurn;
  late final AssistantSession _assistant;
  bool _floatingChatVisible = false;
  bool _voiceOwnsTurn = false;
  final Object _assistantRequestOwner = Object();
  int _assistantRevision = 0;
  String? _assistantDraft;
  String? _lastAssistantScope;

  String _assistantIdentity() {
    if (!mounted) return 'reader-disposed';
    final reading = ref.read(currentReadingProvider);
    final plan = ChatGptPlan.instance;
    final service = Prefs().selectedAiService;
    final config = Prefs().getAiConfig(service);
    final providerIdentity = Object.hash(
      config['url'],
      config['api_key'],
      config['model'],
    );
    return '${reading.isReading}:${reading.book?.id}:${plan.enabled}:${plan.active?.id}:${plan.active?.model}:$service:$providerIdentity';
  }

  String _assistantScope() {
    if (!mounted) return 'reader-disposed';
    final chat = ref.read(aiChatProvider.notifier);
    return '${_assistantIdentity()}:${chat.currentSessionId}:${chat.conversationEpoch}';
  }

  Future<void> _prepareAssistantConversation() => prepareBookAssistantIdentity(
        identity: _assistantIdentity,
        prepare: () =>
            ref.read(aiChatProvider.notifier).ensureSessionForVoice(),
      );

  void _assistantContextChanged() {
    if (!mounted) return;
    final scope = _assistantScope();
    if (_lastAssistantScope != null && _lastAssistantScope != scope) {
      _assistant.onContextChanged();
      _assistantTurn.contextChanged();
    }
    _lastAssistantScope = scope;
  }

  Future<String?> _assistantContext() async {
    dynamic viewport;
    try {
      viewport = await epubPlayerKey.currentState?.webViewController
          .evaluateJavascript(source: readerAssistantViewportScript);
    } catch (_) {}
    final reading = ref.read(currentReadingProvider);
    return buildReaderTutorContext(
      title: _book.title,
      chapter: reading.chapterTitle ?? '',
      viewport: viewport,
      selectionFallback: reading.cfi == _selectionCfi ? _aiSelectedText : null,
    );
  }

  Future<void> _startBookVoice(String language) async {
    if (_assistantTurn.busy) return;
    try {
      await aiChatKey.currentState?.cancelVoiceInput();
      if (audioHandler.playbackState.value.playing) await audioHandler.pause();
      await _prepareAssistantConversation();
      if (!mounted) return;
      _lastAssistantScope = _assistantScope();
      await _assistant.start(language: language);
    } catch (e) {
      AnxToast.show('$e');
    }
  }

  void _closeBookAssistant() {
    _assistant.stop();
    setState(() => _floatingChatVisible = false);
  }

  Future<void> _showIllustrations() async {
    final player = epubPlayerKey.currentState;
    if (player == null) return;
    await _assistant.pause();
    if (!mounted) return;
    await showBookIllustrations(
      context,
      handle: (input) => player.readerImageOperation(input),
      onImported: (id) {
        if (!mounted) return;
        showAiChat(
            content:
                'Insert the illustration I just imported after the paragraph I am reading or the selected passage. Use the most recent imported image and the exact visible text; if the place is ambiguous, ask me.',
            sendImmediate: true);
      },
    );
  }

  Future<void> _showReadingHints() async {
    final controller = epubPlayerKey.currentState?.webViewController;
    if (controller == null) return;
    await _assistant.pause();
    final bookId = _book.id;
    final preferenceKey = 'readerHintFilter:$bookId';
    bool current() =>
        mounted && ref.read(currentReadingProvider).book?.id == bookId;
    Future<Map<String, List<String>>> readTags() async {
      final raw =
          await controller.evaluateJavascript(source: 'getReaderHintTags()');
      return normalizeHintTags(raw is String ? jsonDecode(raw) : raw,
          maxCategories: 128, maxValues: 512);
    }

    try {
      final raw = await controller.evaluateJavascript(
          source: 'getReaderHintControls()');
      final decoded = raw is String ? jsonDecode(raw) : raw;
      final controls =
          decoded is List ? decoded.whereType<Map>().toList() : <Map>[];
      final tags = await readTags();
      final saved =
          ReaderHintFilter.fromJson(Prefs().prefs.getString(preferenceKey));
      final filter = ReaderHintFilter(
          only: saved.only,
          exclude: saved.exclude,
          catalog: saved.tagsWith(tags));
      if (!current()) return;
      await Prefs().prefs.setString(preferenceKey, filter.toJson());
      if (!current()) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ReaderHintSettings(
          controls: controls,
          tags: tags,
          filter: filter,
          setLevel: (id, value) async {
            if (!current()) throw StateError('Book changed');
            return await controller.evaluateJavascript(
                    source: jsCall('setReaderHintLevel', [id, value])) ==
                true;
          },
          setFilter: (next) async {
            if (!current()) throw StateError('Book changed');
            final changed = await controller.evaluateJavascript(
                source: jsCall('setReaderHintFilter', [next.toRules()]));
            if (changed != true || !current())
              throw StateError('Could not apply filter');
            await Prefs().prefs.setString(preferenceKey, next.toJson());
          },
          refresh: controls.any((control) =>
                  control['id']?.toString().startsWith('live:') ?? false)
              ? () async {
                  if (!current()) throw StateError('Book changed');
                  await controller.evaluateJavascript(
                      source: 'refreshReaderHints()');
                  return readTags();
                }
              : null,
        ),
      );
    } catch (_) {
      if (mounted)
        AnxToast.show(
            'Could not load reading hints. Reopen the chapter and try again.');
    }
  }

  final Stopwatch _readTimeWatch = Stopwatch();
  DateTime? _sessionStart;
  Timer? _awakeTimer;
  bool bottomBarOffstage = true;
  late String heroTag;
  Widget? _aiChat;
  final aiChatKey = GlobalKey<AiChatStreamState>();
  static const double _aiChatMinWidth = 240;
  late double _aiChatWidth;
  static const double _aiChatMinHeight = 200;
  late double _aiChatHeight;
  bool _isResizingAiChat = false;
  bool bookmarkExists = false;

  late final FocusNode _readerFocusNode;
  // late final VolumeKeyBoard _volumeKeyBoard;
  // bool _volumeKeyListenerAttached = false;

  @override
  void initState() {
    _readerFocusNode = FocusNode(debugLabel: 'reading_page_focus');
    _assistantTurn = BookAssistantTurn(
      prepare: _prepareAssistantConversation,
      context: _assistantContext,
      scope: _assistantScope,
      cancelBackend: () {
        if (ref.read(aiChatProvider.notifier).ownsTurn(_assistantRequestOwner))
          cancelActiveAiRequest();
      },
      stream: (question, extra) => ref
          .read(aiChatProvider.notifier)
          .sendMessageStream(
            question,
            ref,
            false,
            transientContext: extra,
            requestOwner: _assistantRequestOwner,
            assistantMode: true,
          )
          .map((messages) {
        final answers = messages.whereType<AIChatMessage>();
        if (answers.isEmpty) return '';
        if (mounted &&
            answers.last.content.trim() ==
                L10n.of(context).aiServiceNotConfigured) {
          throw StateError(answers.last.content);
        }
        return parseReasoningContent(answers.last.content)
            .answerTimeline
            .where((entry) => entry.type == ParsedReasoningEntryType.reply)
            .map((entry) => entry.text ?? '')
            .join('\n');
      }),
    );
    _assistant = AssistantSession(
      currentScope: _assistantScope,
      cancelQuestion: () {
        if (_voiceOwnsTurn) _assistantTurn.cancel();
      },
      sendQuestion: (question) async {
        _voiceOwnsTurn = true;
        try {
          return await _assistantTurn.send(question);
        } finally {
          _voiceOwnsTurn = false;
        }
      },
    );
    ChatGptPlan.instance.addListener(_assistantContextChanged);

    // Initialize AI panel sizes from persistent storage
    _aiChatWidth = Prefs().aiPanelWidth;
    _aiChatHeight = Prefs().aiPanelHeight;

    if (widget.book.isDeleted) {
      Navigator.pop(context);
      AnxToast.show(L10n.of(context).bookDeleted);
      return;
    }
    if (Prefs().hideStatusBar) {
      hideStatusBar();
    }

    WidgetsBinding.instance.addObserver(this);
    _readTimeWatch.start();
    _sessionStart = DateTime.now();
    setAwakeTimer(Prefs().awakeTime);

    _book = widget.book;
    heroTag = widget.heroTag ?? 'preventHeroWhenStart';
    // _volumeKeyBoard = VolumeKeyBoard.instance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _requestReaderFocus();
        // _attachVolumeKeyListener();
      }
    });
    // delay 1000ms to prevent hero animation
    if (widget.heroTag == null) {
      Future.delayed(const Duration(milliseconds: 2000), () {
        if (mounted) {
          setState(() {
            heroTag = _book.coverFullPath;
          });
        }
      });
    }
    super.initState();
  }

  @override
  void dispose() {
    ChatGptPlan.instance.removeListener(_assistantContextChanged);
    _assistant.dispose();
    _assistantTurn.dispose();
    Sync().syncData(SyncDirection.upload, ref, trigger: SyncTrigger.auto);
    _readTimeWatch.stop();
    _awakeTimer?.cancel();
    WakelockPlus.disable();
    showStatusBar();
    WidgetsBinding.instance.removeObserver(this);
    readingTimeDao.insertReadingTime(
      ReadingTime(
        bookId: _book.id,
        readingTime: _readTimeWatch.elapsed.inSeconds,
      ),
      startedAt: _sessionStart,
    );
    _sessionStart = null;
    audioHandler.stop();
    // if (_volumeKeyListenerAttached) {
    //   unawaited(_volumeKeyBoard.removeListener());
    // }
    _readerFocusNode.dispose();
    super.dispose();
  }

  void _requestReaderFocus() {
    if (bottomBarOffstage && !_readerFocusNode.hasFocus) {
      _readerFocusNode.requestFocus();
    }
  }

  void _releaseReaderFocus() {
    if (_readerFocusNode.hasFocus) {
      _readerFocusNode.unfocus();
    }
  }

  // Future<void> _attachVolumeKeyListener() async {
  //   if (defaultTargetPlatform != TargetPlatform.iOS ||
  //       _volumeKeyListenerAttached) {
  //     return;
  //   }

  //   try {
  //     await _volumeKeyBoard.addListener(_handleVolumeKeyEvent);
  //     _volumeKeyListenerAttached = true;
  //   } catch (error) {
  //     debugPrint('Failed to attach volume key listener: $error');
  //   }
  // }

  // void _handleVolumeKeyEvent(VolumeKey key) {
  //   if (!Prefs().volumeKeyTurnPage || !_readerFocusNode.hasFocus) {
  //     return;
  //   }

  //   if (key == VolumeKey.up) {
  //     epubPlayerKey.currentState?.prevPage();
  //   } else if (key == VolumeKey.down) {
  //     epubPlayerKey.currentState?.nextPage();
  //   }
  // }

  KeyEventResult _handleReaderKeyEvent(FocusNode node, KeyEvent event) {
    if (!_readerFocusNode.hasFocus) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final logicalKey = event.logicalKey;

    if (logicalKey == LogicalKeyboardKey.arrowRight ||
        logicalKey == LogicalKeyboardKey.arrowDown ||
        logicalKey == LogicalKeyboardKey.pageDown ||
        logicalKey == LogicalKeyboardKey.space) {
      epubPlayerKey.currentState?.nextPage();
      return KeyEventResult.handled;
    }

    if (logicalKey == LogicalKeyboardKey.arrowLeft ||
        logicalKey == LogicalKeyboardKey.arrowUp ||
        logicalKey == LogicalKeyboardKey.pageUp) {
      epubPlayerKey.currentState?.prevPage();
      return KeyEventResult.handled;
    }

    if (logicalKey == LogicalKeyboardKey.enter) {
      showOrHideAppBarAndBottomBar(true);
      return KeyEventResult.handled;
    }

    // Handle Ctrl+[ and Ctrl+] for page turning when keyboard shortcut is enabled
    if (Prefs().keyboardShortcutTurnPage) {
      final isControlPressed = HardwareKeyboard.instance.isControlPressed;
      if (isControlPressed && logicalKey == LogicalKeyboardKey.bracketLeft) {
        epubPlayerKey.currentState?.prevPage();
        return KeyEventResult.handled;
      }
      if (isControlPressed && logicalKey == LogicalKeyboardKey.bracketRight) {
        epubPlayerKey.currentState?.nextPage();
        return KeyEventResult.handled;
      }
      final bool isSimulatedCtrlLeft = event.character == '\u001b';
      final bool isSimulatedCtrlRight = event.character == '\u001d';
      if (isSimulatedCtrlLeft) {
        epubPlayerKey.currentState?.prevPage();
        return KeyEventResult.handled;
      }
      if (isSimulatedCtrlRight) {
        epubPlayerKey.currentState?.nextPage();
        return KeyEventResult.handled;
      }
    }

    if (Prefs().volumeKeyTurnPage) {
      if (event.physicalKey == PhysicalKeyboardKey.audioVolumeUp) {
        epubPlayerKey.currentState?.prevPage();
        return KeyEventResult.handled;
      }
      if (event.physicalKey == PhysicalKeyboardKey.audioVolumeDown) {
        epubPlayerKey.currentState?.nextPage();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) {
      _assistant.onBackground();
      aiChatKey.currentState?.cancelVoiceInput();
    }
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_readTimeWatch.isRunning) {
          _readTimeWatch.start();
        }
        _sessionStart ??= DateTime.now();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_readTimeWatch.isRunning) {
          _readTimeWatch.stop();
        }
        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          final elapsedSeconds = _readTimeWatch.elapsed.inSeconds;
          if (elapsedSeconds > 5) {
            epubPlayerKey.currentState?.saveReadingProgress();
            readingTimeDao.insertReadingTime(
              ReadingTime(bookId: _book.id, readingTime: elapsedSeconds),
              startedAt: _sessionStart,
            );
          }
          _readTimeWatch.reset();
          _sessionStart = null;
        }
        break;
    }
  }

  Future<void> setAwakeTimer(int minutes) async {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    WakelockPlus.enable();
    _awakeTimer = Timer.periodic(Duration(minutes: minutes), (timer) {
      WakelockPlus.disable();
      _awakeTimer?.cancel();
      _awakeTimer = null;
    });
  }

  void resetAwakeTimer() {
    setAwakeTimer(Prefs().awakeTime);
  }

  void showBottomBar() {
    setState(() {
      showStatusBarWithoutResize();
      bottomBarOffstage = false;
      _releaseReaderFocus();
    });
  }

  void hideBottomBar() {
    setState(() {
      _currentPage = empty;
      bottomBarOffstage = true;
      if (Prefs().hideStatusBar) {
        hideStatusBar();
      }
      _requestReaderFocus();
    });
  }

  void showOrHideAppBarAndBottomBar(bool show) {
    if (show) {
      showBottomBar();
    } else {
      hideBottomBar();
    }
  }

  Future<void> tocHandler() async {
    hideBottomBar();
    _scaffoldKey.currentState?.openDrawer();
  }

  void noteHandler() {
    setState(() {
      _currentPage = ReadingNotes(book: _book);
    });
  }

  void progressHandler() {
    setState(() {
      _currentPage = ProgressWidget(
        epubPlayerKey: epubPlayerKey,
        showOrHideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
      );
    });
  }

  Future<void> styleHandler(StateSetter modalSetState) async {
    List<ReadTheme> themes = await themeDao.selectThemes();
    setState(() {
      _currentPage = StyleWidget(
        themes: themes,
        epubPlayerKey: epubPlayerKey,
        setCurrentPage: (Widget page) {
          modalSetState(() {
            _currentPage = page;
          });
        },
        hideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
      );
    });
  }

  Future<void> ttsHandler() async {
    setState(() {
      _currentPage = TtsWidget(epubPlayerKey: epubPlayerKey);
    });
  }

  double _aiChatMaxWidth(BuildContext context) {
    final totalWidth = MediaQuery.of(context).size.width;
    final maxByPercentage = totalWidth * 0.65;
    final maxByRemaining = totalWidth - 320;
    final maxWidth = math.min(maxByPercentage, maxByRemaining);
    return math.max(_aiChatMinWidth, maxWidth);
  }

  double _aiChatMaxHeight(BuildContext context) {
    final totalHeight = MediaQuery.of(context).size.height;
    final maxByPercentage = totalHeight * 0.60;
    final maxByRemaining = totalHeight - 320;
    final maxHeight = math.min(maxByPercentage, maxByRemaining);
    return math.max(_aiChatMinHeight, maxHeight);
  }

  void _beginAiChatResize(double globalDx) {
    setState(() {
      _isResizingAiChat = true;
    });
  }

  void _applyAiChatResizeDelta(double delta, BuildContext context) {
    final maxWidth = _aiChatMaxWidth(context);
    final updated =
        (_aiChatWidth - delta).clamp(_aiChatMinWidth, maxWidth).toDouble();
    if (updated != _aiChatWidth) {
      setState(() {
        _aiChatWidth = updated;
      });
    }
  }

  void _endAiChatResize() {
    if (_isResizingAiChat) {
      setState(() {
        _isResizingAiChat = false;
      });
      // Save the panel sizes to persistent storage
      Prefs().aiPanelWidth = _aiChatWidth;
      Prefs().aiPanelHeight = _aiChatHeight;
    }
  }

  void _beginAiChatResizeVertical(double globalDy) {
    setState(() {
      _isResizingAiChat = true;
    });
  }

  void _applyAiChatResizeDeltaVertical(double delta, BuildContext context) {
    final maxHeight = _aiChatMaxHeight(context);
    final updated =
        (_aiChatHeight - delta).clamp(_aiChatMinHeight, maxHeight).toDouble();
    if (updated != _aiChatHeight) {
      setState(() {
        _aiChatHeight = updated;
      });
    }
  }

  Future<void> onLoadEnd() async {
    if (Prefs().autoSummaryPreviousContent) {
      final previousContent = await epubPlayerKey.currentState!.previousContent(
        2000,
      );
      final prompt = generatePromptSummaryThePreviousContent(previousContent);
      SmartDialog.show(
        builder: (context) => AlertDialog(
          title: Text(L10n.of(context).readingPageSummaryPreviousContent),
          content: AiStream(prompt: prompt),
        ),
        onDismiss: () {
          cancelActiveAiRequest();
        },
      );
    }
  }

  List<Widget> _buildAiChatTrailing(BuildContext context) {
    return [
      IconButton(
        onPressed: () {
          setState(() {
            Prefs().aiPanelPosition =
                Prefs().aiPanelPosition == AiPanelPositionEnum.right
                    ? AiPanelPositionEnum.bottom
                    : AiPanelPositionEnum.right;
            // Rebuild the _aiChat widget to update the button
            _rebuildAiChat();
          });
        },
        icon: Icon(
          Prefs().aiPanelPosition == AiPanelPositionEnum.right
              ? Icons.arrow_downward
              : Icons.arrow_forward,
        ),
        tooltip: Prefs().aiPanelPosition == AiPanelPositionEnum.right
            ? L10n.of(context).aiShowAtBottom
            : L10n.of(context).aiShowAtRight,
      ),
      IconButton(
        onPressed: () {
          setState(() {
            _aiChat = null;
          });
        },
        icon: const Icon(Icons.close),
      ),
    ];
  }

  void _rebuildAiChat() {
    if (_aiChat == null) return;
    final maxWidth = _aiChatMaxWidth(context);
    final maxHeight = _aiChatMaxHeight(context);
    _aiChatWidth = _aiChatWidth.clamp(_aiChatMinWidth, maxWidth);
    _aiChatHeight = _aiChatHeight.clamp(_aiChatMinHeight, maxHeight);
    _aiChat = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: AiChatStream(
            key: aiChatKey,
            initialMessage: null,
            selectedText: _aiSelectedText,
            sendImmediate: false,
            quickPromptChips: _getAiQuickPromptChips(),
            trailing: _buildAiChatTrailing(context),
          ),
        ),
      ],
    );
  }

  List<AiQuickPromptChip> _getAiQuickPromptChips() {
    return [
      AiQuickPromptChip(
        icon: EvaIcons.book,
        label: L10n.of(context).settingsAiPromptSummaryTheChapter,
        prompt: generatePromptSummaryTheChapter().buildString(),
      ),
      AiQuickPromptChip(
        icon: Icons.menu_book_rounded,
        label: L10n.of(context).settingsAiPromptSummaryTheBook,
        prompt: generatePromptSummaryTheBook().buildString(),
      ),
      AiQuickPromptChip(
        icon: Icons.account_tree_outlined,
        label: L10n.of(context).settingsAiPromptMindmap,
        prompt: generatePromptMindmap().buildString(),
      ),
      // User custom prompts (enabled only)
      ...Prefs().userPrompts.where((p) => p.enabled).map(
            (userPrompt) => AiQuickPromptChip(
              icon: Icons.person_outline,
              label: userPrompt.name,
              prompt: userPrompt.content,
            ),
          ),
    ];
  }

  Future<void> showAiChat({
    String? content,
    String? selectedText,
    bool sendImmediate = false,
  }) async {
    _aiSelectedText = selectedText;
    _selectionCfi = ref.read(currentReadingProvider).cfi;
    _assistantDraft = sendImmediate ? null : content;
    setState(() {
      _floatingChatVisible = true;
      _assistantRevision++;
    });
    showOrHideAppBarAndBottomBar(false);
    if (sendImmediate && content?.trim().isNotEmpty == true) {
      _assistant.pause();
      try {
        await _assistantTurn.send(content!);
      } catch (_) {}
    }
  }

  Future<void> showAiChatHistory({
    String? content,
    String? selectedText,
    bool sendImmediate = false,
  }) async {
    _assistant.pause();
    List<AiQuickPromptChip> quickPrompts = _getAiQuickPromptChips();

    // Determine display mode
    final displayMode = Prefs().aiChatDisplayMode;
    final screenWidth = MediaQuery.of(navigatorKey.currentContext!).size.width;

    bool shouldShowAsPopup = false;

    switch (displayMode) {
      case AiChatDisplayMode.adaptive:
        // Show as popup if width < 600
        shouldShowAsPopup = screenWidth < 600;
        break;
      case AiChatDisplayMode.popup:
        // Always show as popup
        shouldShowAsPopup = true;
        break;
      case AiChatDisplayMode.split:
        // Always show as split screen
        shouldShowAsPopup = false;
        break;
    }

    if (shouldShowAsPopup) {
      showModalBottomSheet(
        context: navigatorKey.currentContext!,
        isScrollControlled: true,
        showDragHandle: false,
        clipBehavior: Clip.hardEdge,
        builder: (context) => PointerInterceptor(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: AiChatStream(
                key: aiChatKey,
                initialMessage: content,
                selectedText: selectedText,
                sendImmediate: sendImmediate,
                quickPromptChips: quickPrompts,
              ),
            ),
          ),
        ),
      );
    } else {
      setState(() {
        final maxWidth = _aiChatMaxWidth(navigatorKey.currentContext!);
        final maxHeight = _aiChatMaxHeight(navigatorKey.currentContext!);
        _aiChatWidth = _aiChatWidth.clamp(_aiChatMinWidth, maxWidth);
        _aiChatHeight = _aiChatHeight.clamp(_aiChatMinHeight, maxHeight);
        _aiChat = Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: AiChatStream(
                key: aiChatKey,
                initialMessage: content,
                selectedText: selectedText,
                sendImmediate: sendImmediate,
                quickPromptChips: quickPrompts,
                trailing: _buildAiChatTrailing(navigatorKey.currentContext!),
              ),
            ),
          ],
        );
      });
    }
  }

  void updateState() {
    if (mounted) {
      setState(() {
        bookmarkExists = epubPlayerKey.currentState!.bookmarkExists;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentReadingProvider, (_, __) => _assistantContextChanged());
    ref.listen(aiChatProvider, (_, __) => _assistantContextChanged());
    ref.listen(aiProvidersProvider, (_, __) => _assistantContextChanged());
    var aiButton = IconButton(
      tooltip: L10n.of(context).aiChat,
      icon: const Icon(Icons.auto_awesome),
      onPressed: () async {
        showOrHideAppBarAndBottomBar(false);
        showAiChat();
      },
    );
    Offstage controller = Offstage(
      offstage: bottomBarOffstage,
      child: PointerInterceptor(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  showOrHideAppBarAndBottomBar(false);
                },
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) {},
                onVerticalDragEnd: (details) {},
                child: Container(color: Colors.black.withAlpha(30)),
              ),
            ),
            Column(
              children: [
                AppBar(
                  title: Text(_book.title, overflow: TextOverflow.ellipsis),
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      // close reading page
                      Navigator.pop(context);
                    },
                  ),
                  actions: [
                    if (EnvVar.enableAIFeature) aiButton,
                    IconButton(
                      icon: const Icon(Icons.copy),
                      tooltip: L10n.of(context).readingPageCopyChapterContent,
                      onPressed: () async {
                        try {
                          var content = await epubPlayerKey.currentState
                              ?.theChapterContent();
                          var len = content?.length ?? 0;
                          if (len > 0) {
                            await Clipboard.setData(
                              ClipboardData(text: content!),
                            );
                          }
                          AnxToast.show(
                            L10n.of(context).readingPageCopiedCharacters(len),
                          );
                        } catch (e) {
                          AnxToast.show(
                            L10n.of(context).readingPageErrorCopyingContent,
                          );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: L10n.of(context).readingPageBookmark,
                      onPressed: () {
                        if (bookmarkExists) {
                          epubPlayerKey.currentState!.removeAnnotation(
                            epubPlayerKey.currentState!.bookmarkCfi,
                          );
                        } else {
                          epubPlayerKey.currentState!.addBookmarkHere();
                        }
                      },
                      icon: bookmarkExists
                          ? const Icon(Icons.bookmark)
                          : const Icon(Icons.bookmark_border),
                    ),
                    IconButton(
                      tooltip: L10n.of(context).readingPageBookDetails,
                      icon: const Icon(EvaIcons.more_vertical),
                      onPressed: () {
                        Navigator.push(
                          context,
                          CupertinoPageRoute(
                            builder: (context) => BookDetail(book: widget.book),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const Spacer(),
                BottomSheet(
                  onClosing: () {},
                  enableDrag: false,
                  builder: (context) => SafeArea(
                    top: false,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 600),
                      child: StatefulBuilder(
                        builder: (BuildContext context, StateSetter setState) {
                          final hasContent = !identical(_currentPage, empty);
                          return IntrinsicHeight(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hasContent) Expanded(child: _currentPage),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceAround,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.toc),
                                      onPressed: tocHandler,
                                    ),
                                    IconButton(
                                      icon: const Icon(EvaIcons.edit),
                                      onPressed: noteHandler,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.data_usage),
                                      onPressed: progressHandler,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.color_lens),
                                      onPressed: () {
                                        styleHandler(setState);
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(EvaIcons.headphones),
                                      onPressed: ttsHandler,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Hero(
        tag: widget.heroTag ??
            (Prefs().openBookAnimation ? _book.coverFullPath : heroTag),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            height: MediaQuery.of(context).size.height,
            width: MediaQuery.of(context).size.width,
            child: Scaffold(
              key: _scaffoldKey,
              resizeToAvoidBottomInset: false,
              drawer: PointerInterceptor(
                child: Drawer(
                  width: math.min(MediaQuery.of(context).size.width * 0.8, 420),
                  child: SafeArea(
                    child: TocWidget(
                      epubPlayerKey: epubPlayerKey,
                      hideAppBarAndBottomBar: showOrHideAppBarAndBottomBar,
                      closeDrawer: () {
                        _scaffoldKey.currentState?.closeDrawer();
                      },
                    ),
                  ),
                ),
              ),
              body: Stack(
                children: [
                  AxisFlex(
                    axis: Prefs().aiPanelPosition == AiPanelPositionEnum.right
                        ? Axis.horizontal
                        : Axis.vertical,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: MouseRegion(
                          onHover: (PointerHoverEvent detail) {
                            if (!Prefs().showMenuOnHover) return;
                            var y = detail.position.dy;
                            if (y < 30 ||
                                y > MediaQuery.of(context).size.height - 30) {
                              showOrHideAppBarAndBottomBar(true);
                            }
                          },
                          child: Focus(
                            focusNode: _readerFocusNode,
                            onKeyEvent: _handleReaderKeyEvent,
                            child: Stack(
                              children: [
                                EpubPlayer(
                                  key: epubPlayerKey,
                                  book: _book,
                                  cfi: widget.cfi,
                                  showOrHideAppBarAndBottomBar:
                                      showOrHideAppBarAndBottomBar,
                                  onLoadEnd: onLoadEnd,
                                  initialThemes: widget.initialThemes,
                                  updateParent: updateState,
                                ),
                                if (_isResizingAiChat)
                                  SizedBox.expand(
                                    child: Container(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surface.withAlpha(1),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_aiChat != null)
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.right
                              ? (details) {
                                  _beginAiChatResize(details.globalPosition.dx);
                                }
                              : null,
                          onHorizontalDragUpdate: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.right
                              ? (details) {
                                  _applyAiChatResizeDelta(
                                    details.delta.dx,
                                    context,
                                  );
                                }
                              : null,
                          onHorizontalDragEnd: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.right
                              ? (_) {
                                  _endAiChatResize();
                                }
                              : null,
                          onHorizontalDragCancel: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.right
                              ? () {
                                  _endAiChatResize();
                                }
                              : null,
                          onVerticalDragStart: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.bottom
                              ? (details) {
                                  _beginAiChatResizeVertical(
                                    details.globalPosition.dy,
                                  );
                                }
                              : null,
                          onVerticalDragUpdate: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.bottom
                              ? (details) {
                                  _applyAiChatResizeDeltaVertical(
                                    details.delta.dy,
                                    context,
                                  );
                                }
                              : null,
                          onVerticalDragEnd: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.bottom
                              ? (_) {
                                  _endAiChatResize();
                                }
                              : null,
                          onVerticalDragCancel: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.bottom
                              ? () {
                                  _endAiChatResize();
                                }
                              : null,
                          child: MouseRegion(
                            cursor: Prefs().aiPanelPosition ==
                                    AiPanelPositionEnum.right
                                ? SystemMouseCursors.resizeColumn
                                : SystemMouseCursors.resizeRow,
                            child: Prefs().aiPanelPosition ==
                                    AiPanelPositionEnum.right
                                ? VerticalDivider(width: 2, thickness: 1)
                                : Divider(height: 2, thickness: 1),
                          ),
                        ),
                      if (_aiChat != null)
                        SizedBox(
                          key: const ValueKey('ai-chat-panel'),
                          width: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.right
                              ? _aiChatWidth
                              : null,
                          height: Prefs().aiPanelPosition ==
                                  AiPanelPositionEnum.bottom
                              ? _aiChatHeight
                              : null,
                          child: _aiChat,
                        ),
                    ],
                  ),
                  controller,
                  if (_floatingChatVisible)
                    Positioned.fill(
                      child: FloatingBookAssistant(
                        session: _assistant,
                        turn: _assistantTurn,
                        scope: _assistantScope,
                        startVoice: _startBookVoice,
                        close: _closeBookAssistant,
                        hints: _showReadingHints,
                        illustrations: _showIllustrations,
                        history: () {
                          _assistant.pause();
                          setState(() => _floatingChatVisible = false);
                          showAiChatHistory();
                        },
                        draft: _assistantDraft,
                        revision: _assistantRevision,
                      ),
                    ),
                  // TTS floating action button: always in the tree when toolbar
                  // is hidden; TtsFab handles its own show/hide internally so
                  // its State (expanded flag) is never destroyed mid-session.
                  if (bottomBarOffstage)
                    const Positioned(right: 16, bottom: 24, child: TtsFab()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
