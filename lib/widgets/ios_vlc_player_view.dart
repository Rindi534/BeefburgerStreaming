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

/// Eine Audio- oder Untertitel-Spur wie MobileVLCKit sie ausgibt.
/// [id]=-1 kennzeichnet je nach Kontext "deaktiviert" (Subtitle-Off)
/// oder eine VLC-interne Pseudo-Spur; die UI sollte das prüfen.
class VlcTrack {
  final int id;
  final String name;
  final bool isCurrent;

  const VlcTrack({
    required this.id,
    required this.name,
    required this.isCurrent,
  });
}

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
  // Diagnose-Stream: einmalig die Probe-Botschaft aus VLCPlayerPlugin.swift
  // Schritt 1 von "echtes PiP für VLC". UI zeigt das als Snackbar an.
  final _probeCtrl = StreamController<({bool ok, String message})>.broadcast();
  Stream<({bool ok, String message})> get probeStream => _probeCtrl.stream;

  // Subtitle-Diagnose: zeigt was nach setSubtitleTrack tatsächlich
  // bei libvlc angekommen ist. Wird als SnackBar im Player-Screen
  // angezeigt um zu klären warum die Subs nicht erscheinen.
  final _subDebugCtrl = StreamController<String>.broadcast();
  Stream<String> get subDebugStream => _subDebugCtrl.stream;

  // Lockscreen-Remote-Commands. iOS feuert das wenn der User
  // im Sperrbildschirm den Next-/Previous-Track-Button drückt
  // (oder via Headphones / CarPlay). Player-Screen hört darauf
  // und triggert die Folgen-Navigation.
  final _remoteNextCtrl = StreamController<void>.broadcast();
  Stream<void> get remoteNextStream => _remoteNextCtrl.stream;
  final _remotePrevCtrl = StreamController<void>.broadcast();
  Stream<void> get remotePrevStream => _remotePrevCtrl.stream;

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
      case 'probeResult':
        final ok = raw['ok'] as bool? ?? false;
        final msg = raw['message'] as String? ?? '(no message)';
        _probeCtrl.add((ok: ok, message: msg));
        break;
      case 'subDebug':
        final reqId = raw['requestedId'];
        final wrapper = raw['wrapperCurrent'];
        final libOk = raw['libvlcSetOk'];
        final libCur = raw['libvlcCurrent'];
        _subDebugCtrl.add(
          'sub req=$reqId wrap=$wrapper lib-ok=$libOk lib-cur=$libCur',
        );
        break;
      case 'formatDiag':
        final info = raw['info'] as String? ?? '';
        _subDebugCtrl.add('FMT: $info');
        break;
      case 'skipDiag':
        final trace = raw['trace'] as String? ?? '(empty)';
        _subDebugCtrl.add('SKIP: $trace');
        break;
      case 'remoteNextTrack':
        _remoteNextCtrl.add(null);
        break;
      case 'remotePreviousTrack':
        _remotePrevCtrl.add(null);
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

  /// Liste der verfügbaren Audio-Spuren der aktuellen Media. VLC liefert
  /// bei einem MKV z.B. "Deutsch", "Englisch", "Kommentar"; bei manchen
  /// Files ist die erste Spur eine "Disable"-Spur mit id=-1 — das
  /// filtern wir hier NICHT raus, soll der Aufrufer entscheiden.
  Future<List<VlcTrack>> getAudioTracks() async {
    final raw = await _methods.invokeMethod<List<dynamic>>('getAudioTracks');
    return _decodeTracks(raw);
  }

  /// Liste der Untertitel-Spuren. Eintrag mit id=-1 (sofern VLC ihn
  /// zurückliefert) bedeutet "Untertitel aus".
  Future<List<VlcTrack>> getSubtitleTracks() async {
    final raw =
        await _methods.invokeMethod<List<dynamic>>('getSubtitleTracks');
    return _decodeTracks(raw);
  }

  Future<void> setAudioTrack(int id) =>
      _methods.invokeMethod('setAudioTrack', {'id': id});

  Future<void> setSubtitleTrack(int id) =>
      _methods.invokeMethod('setSubtitleTrack', {'id': id});

  /// Diagnose: holt die letzten ~50 KB des libvlc-internen Logs.
  /// Wird im Sub-Debug-Snackbar angezeigt damit wir sehen warum
  /// SPU-Compositing nicht klappt.
  Future<String> getLibvlcLog() async {
    final s = await _methods.invokeMethod<String>('getLibvlcLog');
    return s ?? '';
  }

  /// Setzt die iOS-Lockscreen/Control-Center-Now-Playing-Karte.
  /// title = Episodenname, artist = Serien-/Filmname, artworkPath =
  /// lokaler Pfad zu cover.jpg, duration = Gesamtlänge.
  Future<void> setNowPlayingInfo({
    required String title,
    String? artist,
    String? artworkPath,
    Duration? duration,
  }) =>
      _methods.invokeMethod('setNowPlayingInfo', {
        'title': title,
        if (artist != null) 'artist': artist,
        if (artworkPath != null) 'artworkPath': artworkPath,
        'duration': (duration?.inMilliseconds ?? 0) / 1000.0,
      });

  List<VlcTrack> _decodeTracks(List<dynamic>? raw) {
    if (raw == null) return const [];
    return raw.whereType<Map>().map((m) {
      return VlcTrack(
        id: (m['id'] as num?)?.toInt() ?? -1,
        name: _cleanTrackName((m['name'] as String?) ?? 'Unbekannt'),
        isCurrent: (m['isCurrent'] as bool?) ?? false,
      );
    }).toList();
  }

  /// VLCKit liefert Track-Namen in Formaten wie "English [eng]",
  /// "English - [eng]" oder "Track 1 - English [eng]". Wir wollen in
  /// der UI nur den Roh-Sprachnamen ("English"). Reihenfolge:
  ///   1) Klammer-Suffix " [...]" abschneiden
  ///   2) verbleibenden trailing-Separator " -" / "–" / "—" trimmen
  ///   3) VLC's "Disable" auf "Aus" übersetzen (User-Feedback 1.5.26)
  static String _cleanTrackName(String raw) {
    var s = raw;
    final bracket = s.indexOf(' [');
    if (bracket > 0) s = s.substring(0, bracket);
    s = s.trim();
    while (s.endsWith('-') || s.endsWith('–') || s.endsWith('—')) {
      s = s.substring(0, s.length - 1).trimRight();
    }
    if (s.toLowerCase() == 'disable') return 'Aus';
    return s;
  }

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
      // EagerGestureRecognizer: Flutter "claimed" alle Touches sofort,
      // bevor VLCs UIView sie sehen kann. Ohne das verschlucken die
      // iOS-System-Gesten (oder die leere VLCVideoView, die trotzdem
      // als UIResponder zählt) unsere Taps — dann bleibt der Tap-
      // Catcher im Screen darüber stumm und Controls kommen nach dem
      // Auto-Hide nicht mehr zurück.
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(
          () => EagerGestureRecognizer(),
        ),
      },
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
