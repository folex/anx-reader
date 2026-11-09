import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// An 18-dp edge gesture, limited to the actual reading surface.
///
/// The translucent detector deliberately has no hit-testable/painted child.
/// The underlying platform view remains in the hit-test path. Only an accepted
/// vertical drag wins the gesture arena; taps and horizontal drags stay with it.
class ReaderBrightnessGesture extends StatefulWidget {
  const ReaderBrightnessGesture({
    super.key,
    required this.child,
    this.enabled = true,
    this.canStart,
  });

  final Widget child;
  final bool enabled;
  final bool Function()? canStart;

  @override
  State<ReaderBrightnessGesture> createState() =>
      _ReaderBrightnessGestureState();
}

class _ReaderBrightnessGestureState extends State<ReaderBrightnessGesture> {
  static const channel = MethodChannel(
    'com.anxcye.anx_reader/reader_brightness',
  );
  static const edgeWidth = 18.0;
  static int _nextOwner = 0;
  Timer? _hudTimer;
  bool _ready = false;
  bool _dragging = false;
  bool _sending = false;
  int _dragSerial = 0;
  int _activationEpoch = 0;
  String? _owner;
  String? _dragOwner;
  String? _pendingOwner;
  double _dragDy = 0;
  double _dragHeight = 1;
  double? _startBrightness;
  double? _pendingValue;
  double? _visibleBrightness;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_supported && widget.enabled) unawaited(_activate());
  }

  @override
  void didUpdateWidget(covariant ReaderBrightnessGesture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_supported || oldWidget.enabled == widget.enabled) return;
    if (widget.enabled) {
      unawaited(_activate());
    } else {
      _cancel();
      _ready = false;
      _visibleBrightness = null;
      _deactivate();
    }
  }

  Future<void> _activate() async {
    final epoch = ++_activationEpoch;
    final owner =
        'reader-${DateTime.now().microsecondsSinceEpoch}-${_nextOwner++}';
    _owner = owner;
    _ready = false;
    try {
      await channel.invokeMethod<void>('enterReader', {'owner': owner});
      if (mounted &&
          widget.enabled &&
          epoch == _activationEpoch &&
          _owner == owner) {
        setState(() => _ready = true);
      } else {
        unawaited(_exit(owner));
      }
    } on PlatformException {
      // A missing/unavailable native bridge leaves normal reader gestures intact.
    } on MissingPluginException {
      // Also supports non-Android builds without a brightness plugin.
    }
  }

  void _deactivate() {
    _activationEpoch++;
    final owner = _owner;
    _owner = null;
    if (owner != null) unawaited(_exit(owner));
  }

  Future<void> _exit(String owner) async {
    try {
      await channel.invokeMethod<void>('exitReader', {'owner': owner});
    } on PlatformException {
      // Native Activity background/destroy hooks independently restore the window.
    } on MissingPluginException {
      // No native override was possible.
    }
  }

  bool _canStart() =>
      _ready && widget.enabled && (widget.canStart?.call() ?? true);

  Future<void> _begin(DragStartDetails details, double height) async {
    final serial = ++_dragSerial;
    final owner = _owner;
    if (owner == null) return;
    _dragOwner = owner;
    _dragging = true;
    _dragDy = 0;
    _dragHeight = height > 0 ? height : 1;
    _startBrightness = null;
    _hudTimer?.cancel();
    try {
      final state = await channel.invokeMapMethod<String, dynamic>(
        'getBrightness',
        {'owner': owner},
      );
      final value = state?['brightness'];
      if (!mounted ||
          serial != _dragSerial ||
          _owner != owner ||
          !widget.enabled ||
          state?['active'] != true ||
          value is! num ||
          !value.isFinite)
        return;
      _startBrightness = value.toDouble().clamp(0.0, 1.0);
      _applyDrag();
    } on PlatformException {
      if (mounted && serial == _dragSerial && owner == _owner) _cancel();
    } on MissingPluginException {
      if (mounted && serial == _dragSerial && owner == _owner) _cancel();
    }
  }

  void _update(DragUpdateDetails details) {
    _dragDy += details.delta.dy;
    _applyDrag();
  }

  void _applyDrag() {
    final start = _startBrightness;
    if (start == null || !mounted || !widget.enabled || _dragOwner != _owner)
      return;
    final value = (start - _dragDy / _dragHeight).clamp(0.0, 1.0);
    _pendingValue = value;
    _pendingOwner = _dragOwner;
    setState(() => _visibleBrightness = value);
    if (!_dragging) _scheduleHide();
    if (!_sending) unawaited(_flush());
  }

  Future<void> _flush() async {
    _sending = true;
    try {
      while (mounted && widget.enabled && _pendingValue != null) {
        final value = _pendingValue!;
        final owner = _pendingOwner;
        _pendingValue = null;
        _pendingOwner = null;
        if (owner == null || owner != _owner) continue;
        try {
          await channel.invokeMethod<void>('setBrightness', {
            'value': value,
            'owner': owner,
          });
        } on PlatformException {
          if (owner == _owner) {
            if (_pendingOwner == owner) _pendingValue = null;
            if (mounted) setState(() => _visibleBrightness = null);
          }
        }
      }
    } on PlatformException {
      _pendingValue = null;
      if (mounted) setState(() => _visibleBrightness = null);
    } on MissingPluginException {
      _pendingValue = null;
    } finally {
      _sending = false;
    }
  }

  void _end(DragEndDetails details) {
    _dragging = false;
    _scheduleHide();
  }

  void _scheduleHide() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _visibleBrightness = null);
    });
  }

  void _cancel() {
    _dragSerial++;
    _dragging = false;
    _startBrightness = null;
    _pendingValue = null;
    _pendingOwner = null;
    _hudTimer?.cancel();
    if (mounted) _scheduleHide();
  }

  @override
  void dispose() {
    _dragSerial++;
    _pendingValue = null;
    _pendingOwner = null;
    _hudTimer?.cancel();
    if (_supported) _deactivate();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return widget.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (widget.enabled)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: edgeWidth,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  gestures: {
                    _ReaderEdgeVerticalRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _ReaderEdgeVerticalRecognizer
                        >(
                          () => _ReaderEdgeVerticalRecognizer(debugOwner: this),
                          (recognizer) {
                            recognizer
                              ..canStart = _canStart
                              ..onStart = (details) {
                                unawaited(
                                  _begin(details, constraints.maxHeight),
                                );
                              }
                              ..onUpdate = _update
                              ..onEnd = _end
                              ..onCancel = _cancel;
                          },
                        ),
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            if (_visibleBrightness != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: DecoratedBox(
                      key: const ValueKey('reader-brightness-hud'),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.brightness_6_outlined),
                            const SizedBox(width: 8),
                            Text('${(_visibleBrightness! * 100).round()}%'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ReaderEdgeVerticalRecognizer extends VerticalDragGestureRecognizer {
  _ReaderEdgeVerticalRecognizer({super.debugOwner})
    : super(
        supportedDevices: {PointerDeviceKind.touch, PointerDeviceKind.stylus},
      );

  bool Function()? canStart;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (canStart?.call() ?? false) && super.isPointerAllowed(event);
}

/// Report book-native footnote/dialog visibility so the Flutter edge detector
/// never competes with scrolling inside an HTML popup. No book text is sent.
const readerBrightnessGateScript = r'''
(() => {
  if (window.__anxBrightnessGate) { window.__anxBrightnessGate(); return; }
  let previous = null;
  const publish = () => {
    const footnote = document.getElementById('footnote-dialog');
    const blocked = Boolean(document.querySelector('dialog[open], [aria-modal="true"]'))
      || Boolean(footnote && getComputedStyle(footnote).display !== 'none');
    if (blocked === previous || !window.flutter_inappwebview?.callHandler) return;
    previous = blocked;
    Promise.resolve(window.flutter_inappwebview.callHandler(
      'onReaderBrightnessUiState', {blocked}
    )).catch(() => { previous = null; });
  };
  window.__anxBrightnessGate = publish;
  const observer = new MutationObserver(publish);
  observer.observe(document.documentElement, {
    subtree: true, childList: true, attributes: true,
    attributeFilter: ['open', 'style', 'class', 'hidden', 'aria-modal']
  });
  document.addEventListener('flutterInAppWebViewPlatformReady', publish);
  window.addEventListener('pagehide', () => observer.disconnect(), {once: true});
  publish();
})();
''';
