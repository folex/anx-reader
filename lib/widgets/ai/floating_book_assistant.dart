import 'dart:async';
import 'dart:io';
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
  });
  final AssistantSession session;
  final BookAssistantTurn turn;
  final String Function() scope;
  final Future<void> Function(String) startVoice;
  final VoidCallback close, history;
  final VoidCallback? hints, illustrations;
  final String? draft;
  final int revision;
  @override
  State<FloatingBookAssistant> createState() => _FloatingBookAssistantState();
}

class _FloatingBookAssistantState extends State<FloatingBookAssistant>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
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
    _text.dispose();
    super.dispose();
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
                  Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(
                        widget.session.state == AssistantState.listening
                            ? Icons.mic
                            : Icons.auto_awesome,
                        size: 22,
                        color: widget.session.state == AssistantState.listening
                            ? colors.error
                            : colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (active)
                        IconButton(
                          tooltip: widget.session.state ==
                                      AssistantState.paused ||
                                  widget.session.state == AssistantState.error
                              ? 'Resume listening'
                              : 'Pause',
                          onPressed: () => widget.session.state ==
                                      AssistantState.paused ||
                                  widget.session.state == AssistantState.error
                              ? _voice()
                              : widget.session.pause(),
                          icon: Icon(
                            widget.session.state == AssistantState.paused ||
                                    widget.session.state == AssistantState.error
                                ? Icons.mic
                                : Icons.pause,
                          ),
                        ),
                      IconButton(
                        tooltip: _expanded
                            ? 'Collapse conversation'
                            : 'Show conversation',
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Minimize assistant',
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          setState(() => _minimized = true);
                        },
                        icon: const Icon(Icons.remove),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Assistant menu',
                        onSelected: (value) {
                          if (value == 'hints') widget.hints?.call();
                          if (value == 'illustrations')
                            widget.illustrations?.call();
                          if (value == 'close') widget.close();
                        },
                        itemBuilder: (_) => [
                          if (widget.hints != null)
                            const PopupMenuItem(
                              value: 'hints',
                              child: ListTile(
                                leading: Icon(Icons.subtitles_outlined),
                                title: Text('Reading hints'),
                                contentPadding: EdgeInsets.zero,
                              ),
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
                          const PopupMenuItem(
                            value: 'close',
                            child: ListTile(
                              leading: Icon(Icons.close),
                              title: Text('Close assistant'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
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
              if (!_minimized)
                Positioned(
                  top: top,
                  left: inset,
                  right: inset,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: panel,
                    ),
                  ),
                )
              else
                Positioned(
                  left: position.dx,
                  top: position.dy,
                  child: GestureDetector(
                    key: const ValueKey('assistant-bubble-drag'),
                    onPanUpdate: (event) => setState(() {
                      _bubblePosition = Offset(
                        travel.dx == 0
                            ? 0
                            : ((_bubblePosition.dx * travel.dx +
                                        event.delta.dx) /
                                    travel.dx)
                                .clamp(0, 1),
                        travel.dy == 0
                            ? 0
                            : ((_bubblePosition.dy * travel.dy +
                                        event.delta.dy) /
                                    travel.dy)
                                .clamp(0, 1),
                      );
                    }),
                    child: Material(
                      color: colors.surfaceContainerHigh,
                      elevation: 4,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox.square(
                        dimension: size,
                        child: IconButton(
                          key: const ValueKey('assistant-bubble'),
                          tooltip: 'Open assistant: $_status',
                          onPressed: () => setState(() => _minimized = false),
                          icon: Icon(
                            widget.session.state == AssistantState.paused
                                ? Icons.mic_off_outlined
                                : Icons.mic,
                            color:
                                error != null ? colors.error : colors.primary,
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
