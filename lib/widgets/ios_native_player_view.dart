// iOS-only wrapper around the native AVPlayerViewController bridge
// defined in ios/Runner/NativePlayerPlugin.swift.
//
// Design rationale:
//   * On Windows we use media_kit (libmpv). On iOS we use AVPlayer
//     directly because only AVPlayer gives us system PiP and AirPlay.
//   * The native side ships its own full playback UI
//     (AVPlayerViewController chrome). We do NOT draw any Flutter
//     controls on top — that would fight the native gestures and
//     cause z-order nastiness with the PiP transition.
//   * We still listen to position/duration/completed events from the
//     native side so Flutter-level bookkeeping (watch-progress save,
//     auto-next episode) keeps working identically to the desktop
//     build.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Imperative handle to a single iOS native player instance.
/// One-to-one with a mounted [IOSNativePlayerView].
class IOSNativePlayerController {
  IOSNativePlayerController._(this._methods, this._events) {
    _events.listen(_onEvent);
  }

  final MethodChannel _methods;
  final Stream<dynamic> _events;

  // Mirrored state — kept here so Dart callers don't need to async-poll
  // the native side for trivial properties.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  String? _lastError;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();

  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _playing;
  bool get isCompleted => _completed;
  String? get lastError => _lastError;

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;

  void _onEvent(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['event']) {
      case 'position':
        final s = (raw['seconds'] as num?)?.toDouble() ?? 0;
        _position = Duration(milliseconds: (s * 1000).round());
        _positionCtrl.add(_position);
        break;
      case 'duration':
        final s = (raw['seconds'] as num?)?.toDouble() ?? 0;
        _duration = Duration(milliseconds: (s * 1000).round());
        _durationCtrl.add(_duration);
        break;
      case 'playing':
        _playing = raw['value'] as bool? ?? false;
        _playingCtrl.add(_playing);
        break;
      case 'completed':
        _completed = true;
        _completedCtrl.add(true);
        break;
      case 'error':
        _lastError = raw['message'] as String?;
        if (_lastError != null) _errorCtrl.add(_lastError!);
        break;
      case 'warning':
        // External .srt is currently unsupported on iOS — ignore
        // silently. Embedded subs in .mkv work via the native UI.
        break;
    }
  }

  Future<void> play() => _methods.invokeMethod('play');
  Future<void> pause() => _methods.invokeMethod('pause');
  Future<void> seek(Duration pos) =>
      _methods.invokeMethod('seek', {'seconds': pos.inMilliseconds / 1000.0});
  Future<void> setVolume(double v) =>
      _methods.invokeMethod('setVolume', {'volume': v.clamp(0.0, 1.0)});
  Future<void> setRate(double r) =>
      _methods.invokeMethod('setRate', {'rate': r});

  Future<void> dispose() async {
    try {
      await _methods.invokeMethod('dispose');
    } catch (_) {}
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _playingCtrl.close();
    await _completedCtrl.close();
    await _errorCtrl.close();
  }
}

/// Flutter widget that hosts AVPlayerViewController as a native
/// platform view. Takes a single callback to hand back the controller
/// once the native side is ready to receive commands.
class IOSNativePlayerView extends StatefulWidget {
  final String filePath;
  final String? subtitlePath;
  final Duration? startPosition;
  final ValueChanged<IOSNativePlayerController>? onReady;

  const IOSNativePlayerView({
    super.key,
    required this.filePath,
    this.subtitlePath,
    this.startPosition,
    this.onReady,
  });

  @override
  State<IOSNativePlayerView> createState() => _IOSNativePlayerViewState();
}

class _IOSNativePlayerViewState extends State<IOSNativePlayerView> {
  IOSNativePlayerController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // UiKitView is the iOS/iPadOS-specific platform view. It embeds a
    // UIView (here: our AVPlayerViewController.view) into the Flutter
    // render tree.
    const viewType = 'beefburger/native_player';

    final args = <String, dynamic>{
      'mediaUrl': widget.filePath,
      if (widget.subtitlePath != null) 'subtitleUrl': widget.subtitlePath,
      if (widget.startPosition != null)
        'startSeconds': widget.startPosition!.inMilliseconds / 1000.0,
    };

    return UiKitView(
      viewType: viewType,
      creationParams: args,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onCreated,
      // Propagate gestures to native side — AVPlayerViewController
      // needs taps/drags to run its own chrome (scrub, pinch-to-zoom,
      // swipe-up-to-dismiss in PiP).
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }

  void _onCreated(int viewId) {
    final methods = MethodChannel('beefburger/native_player/methods/$viewId');
    final events =
        EventChannel('beefburger/native_player/events/$viewId').receiveBroadcastStream();
    final ctrl = IOSNativePlayerController._(methods, events);
    setState(() => _controller = ctrl);
    widget.onReady?.call(ctrl);
  }
}

