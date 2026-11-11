import 'assistant_orb.dart';
import 'package:anx_reader/service/voice/assistant_activity.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:anx_reader/service/voice/assistant_session.dart';
import 'package:anx_reader/service/voice/book_assistant_turn.dart';
import 'package:anx_reader/service/voice/reader_voice.dart';

class FloatingBookAssistant extends StatefulWidget {
  const FloatingBookAssistant({
    super.key,
    required this.session,
    required this.turn,
    required this.scope,
    required this.startVoice,
    required this.close,
    required this.history,
    this.hints,
    this.illustrations,
    this.draft,
    this.revision = 0,
    this.reusePreviousChat = true,
    this.onReusePreviousChat,
  });
  final AssistantSession session;
  final BookAssistantTurn turn;
  final String Function() scope;
  final Future<void> Function(String) startVoice;
  final VoidCallback close, history;
  final VoidCallback? hints, illustrations;
  final String? draft;
  final int revision;
  final bool reusePreviousChat;
  final ValueChanged<bool>? onReusePreviousChat;
  @override
  State<FloatingBookAssistant> createState() => _FloatingBookAssistantState();
}

class _FloatingBookAssistantState extends State<FloatingBookAssistant>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _inputFocus = FocusNode();
  PointerDownEvent? _outsideDown;
  final _dismissTarget = GlobalKey();
  Timer? _holdToSpeak;
  Offset? _heldDragOffset;
  bool _showDismissTarget = false;
  bool _overDismissTarget = false;
  late final ReaderVoiceController _dictation;
  bool _expanded = true;
  bool _minimized = false;
  Offset _bubblePosition = const Offset(1, 0);
  String _language = 'ru-RU';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _text.text = widget.draft ?? '';
    _dictation = ReaderVoiceController(
      currentScope: widget.scope,
      onDraft: (value) {
        if (!mounted) return;
        _text.text = insertVoiceDraft(
          _text.text,
          _text.selection.baseOffset < 0
              ? _text.text.length
              : _text.selection.baseOffset,
          value,
        );
        _text.selection = TextSelection.collapsed(offset: _text.text.length);
      },
    );
  }

  @override
  void didUpdateWidget(covariant FloatingBookAssistant oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _expanded = true;
      _minimized = false;
      if (widget.draft != null) _text.text = widget.draft!;
    }
    _dictation.contextChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_dictation.cancel());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dictation.dispose();
    _holdToSpeak?.cancel();
    _inputFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _minimize() {
    _outsideDown = null;
    _inputFocus.unfocus();
    setState(() => _minimized = true);
  }

  void _onOutsideUp(PointerUpEvent event) {
    final down = _outsideDown;
    _outsideDown = null;
    if (down != null &&
        down.pointer == event.pointer &&
        (event.position - down.position).distance <= kTouchSlop) {
      _minimize();
    }
  }

  void _startBubbleHold(LongPressStartDetails details) {
    _heldDragOffset = Offset.zero;
    setState(() => _showDismissTarget = true);
    _holdToSpeak = Timer(const Duration(milliseconds: 350), () async {
      switch (widget.session.state) {
        case AssistantState.thinking:
        case AssistantState.speaking:
          await widget.session.interrupt();
        case AssistantState.listening:
        case AssistantState.transcribing:
          break;
        default:
          await _voice();
      }
    });
  }

  bool _isOverDismissTarget(Offset position) {
    final target = _dismissTarget.currentContext?.findRenderObject();
    return target is RenderBox &&
        (target.localToGlobal(Offset.zero) & target.size).contains(position);
  }

  void _moveBubble(Offset delta, Offset travel) {
    _bubblePosition = Offset(
      travel.dx == 0
          ? 0
          : (_bubblePosition.dx + delta.dx / travel.dx).clamp(0, 1),
      travel.dy == 0
          ? 0
          : (_bubblePosition.dy + delta.dy / travel.dy).clamp(0, 1),
    );
  }

  void _moveHeldBubble(LongPressMoveUpdateDetails details, Offset travel) {
    final previous = _heldDragOffset;
    if (previous == null ||
        (previous == Offset.zero &&
            details.offsetFromOrigin.distance <= kTouchSlop)) {
      return;
    }
    _holdToSpeak?.cancel();
    setState(() {
      _moveBubble(details.offsetFromOrigin - previous, travel);
      _heldDragOffset = details.offsetFromOrigin;
      _overDismissTarget = _isOverDismissTarget(details.globalPosition);
    });
  }

  void _endBubbleHold([Offset? position]) {
    if (!_showDismissTarget) return;
    _holdToSpeak?.cancel();
    final dismiss = position != null &&
        _heldDragOffset != Offset.zero &&
        _isOverDismissTarget(position);
    setState(() {
      _showDismissTarget = false;
      _overDismissTarget = false;
      _heldDragOffset = null;
    });
    if (dismiss) widget.close();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || widget.turn.busy) return;
    widget.session.pause();
    await _dictation.cancel();
    if (!mounted) return;
    _text.clear();
    try {
      await widget.turn.send(text);
    } catch (_) {}
  }

  Future<void> _voice() async {
    await _dictation.cancel();
    if (!mounted) return;
    setState(() => _expanded = false);
    try {
      await widget.startVoice(_language);
    } catch (_) {}
  }

  String get _status => switch (widget.session.state) {
        AssistantState.listening => 'Listening',
        AssistantState.transcribing => 'Transcribing',
        AssistantState.thinking => 'Thinking',
        AssistantState.speaking => 'Speaking',
        AssistantState.paused => 'Paused',
        AssistantState.error => 'Needs attention',
        AssistantState.inactive =>
          widget.turn.busy ? 'Thinking' : 'Book assistant',
      };
  AssistantOrbState get _orbState {
    if (widget.session.state == AssistantState.speaking)
      return AssistantOrbState.speaking;
    if (widget.turn.activity == AssistantActivity.disconnected)
      return AssistantOrbState.disconnected;
    if (widget.turn.busy)
      return switch (widget.turn.activity) {
        AssistantActivity.tools => AssistantOrbState.tools,
        AssistantActivity.connecting => AssistantOrbState.connecting,
        _ => AssistantOrbState.thinking,
      };
    if (widget.session.error != null || widget.turn.error != null)
      return AssistantOrbState.error;
    return switch (widget.session.state) {
      AssistantState.listening ||
      AssistantState.transcribing =>
        AssistantOrbState.listening,
      AssistantState.thinking => AssistantOrbState.thinking,
      AssistantState.paused => AssistantOrbState.paused,
      _ => AssistantOrbState.idle,
    };
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([widget.session, widget.turn, _dictation]),
        builder: (context, _) {
          final theme = Theme.of(context), colors = theme.colorScheme;
          final active = widget.session.active;
          final busy = widget.turn.busy;
          final error = widget.session.error ?? widget.turn.error;
          final question = widget.session.transcript.isNotEmpty && active
              ? widget.session.transcript
              : widget.turn.question;
          final reply = widget.turn.reply.isNotEmpty
              ? widget.turn.reply
              : widget.session.reply;
          final panel = Material(
            elevation: 6,
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .52,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final title = Row(
                        children: [
                          const SizedBox(width: 12),
                          SizedBox.square(
                            dimension: 30,
                            child: AssistantOrb(state: _orbState),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Book assistant',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        ],
                      );
                      final actions = Wrap(
                        alignment: WrapAlignment.end,
                        children: [
                          if (active &&
                              (widget.session.state ==
                                      AssistantState.speaking ||
                                  widget.session.state ==
                                      AssistantState.thinking))
                            IconButton(
                              tooltip: 'Interrupt and speak',
                              onPressed: widget.session.interrupt,
                              icon: const Icon(Icons.front_hand_outlined),
                            )
                          else if (active)
                            IconButton(
                              tooltip: widget.session.state ==
                                          AssistantState.paused ||
                                      widget.session.state ==
                                          AssistantState.error
                                  ? 'Resume listening'
                                  : 'Pause',
                              onPressed: () => widget.session.state ==
                                          AssistantState.paused ||
                                      widget.session.state ==
                                          AssistantState.error
                                  ? _voice()
                                  : widget.session.pause(),
                              icon: Icon(
                                widget.session.state == AssistantState.paused ||
                                        widget.session.state ==
                                            AssistantState.error
                                    ? Icons.mic
                                    : Icons.pause,
                              ),
                            ),
                          IconButton(
                            tooltip: _expanded
                                ? 'Collapse conversation'
                                : 'Show conversation',
                            onPressed: () =>
                                setState(() => _expanded = !_expanded),
                            icon: Icon(
                              _expanded ? Icons.expand_less : Icons.expand_more,
                            ),
                          ),
                          if (widget.hints != null)
                            IconButton(
                              tooltip: 'Reading hints',
                              onPressed: widget.hints,
                              icon: const Icon(Icons.subtitles_outlined),
                            ),
                          IconButton(
                            tooltip: 'Minimize assistant',
                            onPressed: _minimize,
                            icon: const Icon(Icons.remove),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Assistant menu',
                            onSelected: (value) {
                              if (value == 'reuse') {
                                widget.onReusePreviousChat
                                    ?.call(!widget.reusePreviousChat);
                              }
                              if (value == 'illustrations') {
                                widget.illustrations?.call();
                              }
                            },
                            itemBuilder: (_) => [
                              CheckedPopupMenuItem(
                                value: 'reuse',
                                checked: widget.reusePreviousChat,
                                enabled:
                                    !busy && widget.onReusePreviousChat != null,
                                child: const Text('Reuse previous chat'),
                              ),
                              if (widget.illustrations != null)
                                const PopupMenuItem(
                                  value: 'illustrations',
                                  child: ListTile(
                                    leading: Icon(Icons.image_outlined),
                                    title: Text('Illustrations'),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                            ],
                          ),
                          IconButton(
                            tooltip: 'Close assistant',
                            onPressed: widget.close,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      );
                      if (constraints.maxWidth < (active ? 448 : 400)) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 8),
                            title,
                            actions,
                          ],
                        );
                      }
                      return Row(children: [Expanded(child: title), actions]);
                    },
                  ),
                  if (!_expanded && error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text(
                        error,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  if (_expanded)
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (question.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  question,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge,
                                ),
                              ),
                            if (reply.isNotEmpty)
                              SelectableText(
                                reply,
                                style: theme.textTheme.bodyMedium,
                              ),
                            if (error != null)
                              Text(error,
                                  style: TextStyle(color: colors.error)),
                            if (busy)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: LinearProgressIndicator(),
                              ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _text,
                              focusNode: _inputFocus,
                              minLines: 1,
                              maxLines: 3,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              decoration: InputDecoration(
                                hintText: 'Ask about the text…',
                                border: const OutlineInputBorder(),
                                suffixIcon: IconButton(
                                  tooltip: 'Send',
                                  onPressed: busy ? null : _send,
                                  icon: const Icon(Icons.arrow_upward),
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                if (Platform.isAndroid)
                                  IconButton(
                                    tooltip: _dictation.canStop
                                        ? 'Stop dictation'
                                        : 'Dictate a question',
                                    onPressed: busy || widget.session.busy
                                        ? null
                                        : () => _dictation.canStop
                                            ? _dictation.stopDictation()
                                            : _dictation.startDictation(),
                                    icon: Icon(
                                      _dictation.canStop
                                          ? Icons.stop_circle
                                          : Icons.mic_none,
                                    ),
                                  ),
                                Expanded(
                                  child: TextButton.icon(
                                    onPressed: busy ? null : _voice,
                                    icon: const Icon(Icons.graphic_eq),
                                    label: const Text(
                                      'Voice assistant',
                                      maxLines: 2,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Chat history',
                                  onPressed: widget.history,
                                  icon: const Icon(Icons.history),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _dictation.busy
                                        ? _dictation.status
                                        : 'Question language',
                                    style: theme.textTheme.labelSmall,
                                    maxLines: 2,
                                  ),
                                ),
                                DropdownButton<String>(
                                  value: _language,
                                  underline: const SizedBox(),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'ru-RU',
                                      child: Text('RU'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'es-ES',
                                      child: Text('ES'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'en-US',
                                      child: Text('EN'),
                                    ),
                                  ],
                                  onChanged: active || _dictation.busy
                                      ? null
                                      : (v) {
                                          if (v != null)
                                            setState(() {
                                              _language = v;
                                              _dictation.setLanguage(v);
                                            });
                                        },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
          return LayoutBuilder(builder: (context, bounds) {
            final media = MediaQuery.of(context);
            const size = 52.0;
            const inset = 12.0;
            final top = media.padding.top + inset;
            final bottom =
                media.padding.bottom + media.viewInsets.bottom + inset;
            final travel = Offset(
              (bounds.maxWidth - size - inset * 2).clamp(0, double.infinity),
              (bounds.maxHeight - size - top - bottom)
                  .clamp(0, double.infinity),
            );
            final position = Offset(
              inset + _bubblePosition.dx * travel.dx,
              top + _bubblePosition.dy * travel.dy,
            );
            return Stack(children: [
              if (_showDismissTarget)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: bottom,
                  child: Center(
                    child: Semantics(
                      key: const ValueKey('assistant-dismiss-target'),
                      label: 'Drop here to close assistant',
                      child: AnimatedContainer(
                        key: _dismissTarget,
                        duration: const Duration(milliseconds: 120),
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: _overDismissTarget
                              ? colors.error
                              : colors.errorContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close,
                          size: 32,
                          color: _overDismissTarget
                              ? colors.onError
                              : colors.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_minimized)
                Positioned(
                  top: top,
                  left: inset,
                  right: inset,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: TapRegion(
                        onTapOutside: (event) => _outsideDown = event,
                        onTapUpOutside: _onOutsideUp,
                        child: panel,
                      ),
                    ),
                  ),
                )
              else
                Positioned(
                  key: const ValueKey('assistant-bubble-position'),
                  left: position.dx,
                  top: position.dy,
                  child: Listener(
                    onPointerCancel: (_) => _endBubbleHold(),
                    child: GestureDetector(
                      key: const ValueKey('assistant-bubble-drag'),
                      onPanUpdate: (event) =>
                          setState(() => _moveBubble(event.delta, travel)),
                      onLongPressStart: _startBubbleHold,
                      onLongPressMoveUpdate: (event) =>
                          _moveHeldBubble(event, travel),
                      onLongPressEnd: (event) =>
                          _endBubbleHold(event.globalPosition),
                      child: Material(
                        color: colors.surfaceContainerHigh,
                        elevation: 4,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox.square(
                          dimension: size,
                          child: TooltipTheme(
                            data: TooltipTheme.of(context).copyWith(
                              triggerMode: TooltipTriggerMode.manual,
                            ),
                            child: IconButton(
                              key: const ValueKey('assistant-bubble'),
                              tooltip: widget.session.state ==
                                          AssistantState.speaking ||
                                      widget.session.state ==
                                          AssistantState.thinking
                                  ? 'Interrupt and speak'
                                  : 'Open assistant: $_status',
                              onPressed: widget.session.state ==
                                          AssistantState.speaking ||
                                      widget.session.state ==
                                          AssistantState.thinking
                                  ? widget.session.interrupt
                                  : () => setState(() => _minimized = false),
                              padding: EdgeInsets.zero,
                              icon: AssistantOrb(state: _orbState),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]);
          });
        },
      );
}
