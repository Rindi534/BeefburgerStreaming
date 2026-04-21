// Dart wrapper um den MobileVLCKit-basierten iOS-Player aus
// ios/Runner/VLCPlayerPlugin.swift. Schwestermodul zu
// ios_native_player_view.dart — absichtlich als eigene Datei
// implementiert statt den AVPlayer-Code zu parametrisieren, damit wir
// die zwei Backends unabhängig weiterentwickeln können (gerade jetzt
// wichtig: Session 2 hängt hier den PiP-Controller dran, ohne dass
// wir Gefahr laufen den AVPlayer-Pfad mitzubrechen).
//
// Das Channel-Protokoll ist identisch zum NativePlayer-Plugin, also
// kann der darüberliegende IOSPlayerScreen die gleichen State-Fields
// und gleichen Event-Listener verwenden — wir binden nur je nach
// Dateiendung die passende Widget-Klasse ein.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Imperative handle zu einer mounten VLC-Player-Instanz.
/// 1:1 zum viewId der zugehörigen [IOSVLCPlayerView].
class IOSVLCPlayerController {
  IOSVLCPlayerController._(this._methods, this._events) {
    _events.listen(_onEvent);
  }

  final MethodChannel _methods;
  final Stream<dynamic> _events;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  String? _lastError;
  bool _pipActive = false;
  bool _pipAvailable = false;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _pipActiveCtrl = StreamController<bool>.broadcast();
  final _pipAvailableCtrl = StreamController<bool>.broadcast();

  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _playing;
  bool get isCompleted => _completed;
  String? get lastError => _lastError;
  bool get isPiPActive => _pipActive;
  bool get isPiPAvailable => _pipAvailable;

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;
  Stream<bool> get pipActiveStream => _pipActiveCtrl.stream;
  Stream<bool> get pipAvailableStream => _pipAvailableCtrl.stream;

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
      case 'pipState':
        _pipActive = raw['value'] as bool? ?? false;
        _pipActiveCtrl.add(_pipActive);
        break;
      case 'pipAvailability':
        _pipAvailable = raw['value'] as bool? ?? false;
        _pipAvailableCtrl.add(_pipAvailable);
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

  Future<void> replaceMedia({
    required String filePath,
    String? subtitlePath,
    Duration startPosition = Duration.zero,
  }) async {
    _position = Duration.zero;
    _duration = Duration.zero;
    _completed = false;
    _lastError = null;
    await _methods.invokeMethod('replaceMedia', {
      'mediaUrl': filePath,
      if (subtitlePath != null) 'subtitleUrl': subtitlePath,
      'startSeconds': startPosition.inMilliseconds / 1000.0,
    });
  }

  Future<void> startPiP() async {
    try {
      await _methods.invokeMethod('startPiP');
    } on PlatformException catch (e) {
      _errorCtrl.add(e.message ?? 'PiP konnte nicht gestartet werden');
    }
  }

  Future<void> stopPiP() => _methods.invokeMethod('stopPiP');

  Future<bool> queryPiPPossible() async {
    try {
      final v = await _methods.invokeMethod<bool>('isPiPPossible');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    try {
      await _methods.invokeMethod('dispose');
    } catch (_) {}
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _playingCtrl.close();
    await _completedCtrl.close();
    await _errorCtrl.close();
    await _pipActiveCtrl.close();
    await _pipAvailableCtrl.close();
  }
}

/// Flutter-Widget das den VLC-Platform-View mountet.
class IOSVLCPlayerView extends StatefulWidget {
  final String filePath;
  final String? subtitlePath;
  final Duration? startPosition;
  final ValueChanged<IOSVLCPlayerController>? onReady;

  const IOSVLCPlayerView({
    super.key,
    required this.filePath,
    this.subtitlePath,
    this.startPosition,
    this.onReady,
  });

  @override
  State<IOSVLCPlayerView> createState() => _IOSVLCPlayerViewState();
}

class _IOSVLCPlayerViewState extends State<IOSVLCPlayerView> {
  IOSVLCPlayerController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const viewType = 'beefburger/vlc_player';

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
      // VLC's drawable UIView muss Touch-Events selbst empfangen
      // können (eingebaute Gesture-Handler, Tap zum Show/Hide der
      // eigenen internen Chrome falls wir die mal enablen). Im
      // aktuellen Setup haben wir noch keine eigene Chrome; sobald
      // wir die auf Flutter-Seite bauen, bleibt dieses Set leer damit
      // Flutter die Gesten dominiert.
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }

  void _onCreated(int viewId) {
    final methods = MethodChannel('beefburger/vlc_player/methods/$viewId');
    final events =
        EventChannel('beefburger/vlc_player/events/$viewId').receiveBroadcastStream();
    final ctrl = IOSVLCPlayerController._(methods, events);
    setState(() => _controller = ctrl);
    widget.onReady?.call(ctrl);
  }
}
