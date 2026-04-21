// iOS-Player-Screen für Dateiformate, die AVPlayer nicht beherrscht
// (.mkv, .avi, .iso, .wmv, .flv). Nutzt MobileVLCKit als Backend
// statt AVPlayer.
//
// Bewusst als separate Datei zu ios_player_screen.dart — obwohl die
// zwei Backends (IOSNativePlayerController / IOSVLCPlayerController)
// identische Schnittstellen haben — weil:
//   * Session 2 wird hier den PiP-Controller via VLCKit's eigener
//     AVPictureInPictureDrawable-API anhängen, was beim AVPlayer-
//     Backend systemisch anders läuft.
//   * Das isoliert den Experimentier-Pfad; ein bug im VLC-Screen
//     bricht nicht die stabile AVPlayer-Wiedergabe von .mp4-Dateien.
//
// Später (wenn beide Backends stabil sind) kann man den gemeinsamen
// Teil in ein abstraktes IOSPlayerScreen-Basis extrahieren. Jetzt
// wäre dieser Refactor vorzeitig.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/episode.dart';
import '../providers/watch_progress_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/ios_vlc_player_view.dart';

class IOSVLCPlayerScreen extends ConsumerStatefulWidget {
  final String filePath;
  final String title;
  final String? episodeTitle;
  final String? mediaId;
  final String? subtitlePath;
  final String? nextEpisodeFilePath;
  final String? nextEpisodeTitle;
  final String? nextEpisodeSubtitlePath;
  final Duration? startPosition;
  final List<Episode>? allEpisodes;
  final int? currentEpisodeIndex;

  const IOSVLCPlayerScreen({
    super.key,
    required this.filePath,
    required this.title,
    this.episodeTitle,
    this.mediaId,
    this.subtitlePath,
    this.nextEpisodeFilePath,
    this.nextEpisodeTitle,
    this.nextEpisodeSubtitlePath,
    this.startPosition,
    this.allEpisodes,
    this.currentEpisodeIndex,
  });

  @override
  ConsumerState<IOSVLCPlayerScreen> createState() =>
      _IOSVLCPlayerScreenState();
}

class _IOSVLCPlayerScreenState extends ConsumerState<IOSVLCPlayerScreen> {
  IOSVLCPlayerController? _controller;
  Timer? _progressTimer;
  Timer? _controlsHideTimer;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _pipActiveSub;
  StreamSubscription<bool>? _pipAvailableSub;

  String? _playbackError;
  bool _completionHandled = false;
  bool _pipActive = false;
  bool _pipAvailable = false;

  // VLCKit hat keine eingebaute Overlay-Chrome — wir zeichnen unsere
  // eigenen minimalen Controls in Flutter darüber. Beim Tap auf den
  // Player erscheinen sie, nach 3s blenden sie aus (wie Apples
  // Standard).
  bool _controlsVisible = true;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  // Mutable per-episode state — analog zum AVPlayer-Pfad damit
  // watch-progress nach einer in-place Episode-Umstellung auf den
  // richtigen Datensatz schreibt.
  late String _currentFilePath;
  late String? _currentEpisodeTitle;
  late String? _currentMediaId;
  // ignore: unused_field
  late String? _currentSubtitlePath;
  late int? _currentEpisodeIndex;

  @override
  void initState() {
    super.initState();
    _currentFilePath = widget.filePath;
    _currentEpisodeTitle = widget.episodeTitle;
    _currentMediaId = widget.mediaId;
    _currentSubtitlePath = widget.subtitlePath;
    _currentEpisodeIndex = widget.currentEpisodeIndex;

    // Landscape-only solange der Player offen ist. iOS akzeptiert
    // landscapeLeft+Right nebeneinander, dann bleibt die Orientation
    // der Tatsachen-Seitenlage des Geräts erhalten (Kabel links oder
    // rechts) statt einer fix forcierten. Restore in dispose().
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _scheduleControlsHide();
  }

  @override
  void dispose() {
    _saveProgress();
    _progressTimer?.cancel();
    _controlsHideTimer?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _pipActiveSub?.cancel();
    _pipAvailableSub?.cancel();

    // Orientation-Lock wieder aufheben — der Rest der App soll sich
    // an der globalen Default-Config orientieren (Portrait-friendly
    // auf iPhone, alles erlaubt auf iPad).
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);

    super.dispose();
  }

  void _scheduleControlsHide() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  void _onReady(IOSVLCPlayerController ctrl) {
    _controller = ctrl;

    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );

    _completedSub = ctrl.completedStream.listen((_) {
      if (_completionHandled) return;
      _completionHandled = true;
      _onPlaybackComplete();
    });

    _errorSub = ctrl.errorStream.listen((msg) {
      if (!mounted) return;
      setState(() => _playbackError = msg);
    });

    _playingSub = ctrl.playingStream.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
    });

    _positionSub = ctrl.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });

    _durationSub = ctrl.durationStream.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur);
    });

    _pipActiveSub = ctrl.pipActiveStream.listen((active) {
      if (!mounted) return;
      setState(() => _pipActive = active);
    });

    _pipAvailableSub = ctrl.pipAvailableStream.listen((avail) {
      if (!mounted) return;
      setState(() => _pipAvailable = avail);
    });
  }

  Future<void> _togglePiP() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    if (_pipActive) {
      await ctrl.stopPiP();
    } else {
      await ctrl.startPiP();
    }
  }

  void _saveProgress({bool treatAsCompleted = false}) {
    final ctrl = _controller;
    final mediaId = _currentMediaId;
    if (ctrl == null || mediaId == null) return;
    final dur = ctrl.duration;
    if (dur.inSeconds <= 0) return;
    final pos = treatAsCompleted ? dur : ctrl.position;
    ref.read(watchProgressProvider.notifier).updateProgress(
          mediaId: mediaId,
          filePath: _currentFilePath,
          position: pos,
          totalDuration: dur,
          mediaTitle: widget.title,
          episodeTitle: _currentEpisodeTitle,
        );
  }

  void _onPlaybackComplete() {
    _saveProgress(treatAsCompleted: true);
    _playNextEpisode();
  }

  Episode? _lookupNextEpisode() {
    final all = widget.allEpisodes;
    final idx = _currentEpisodeIndex;
    if (all == null || idx == null) return null;
    final next = idx + 1;
    if (next >= all.length) return null;
    return all[next];
  }

  void _playNextEpisode() {
    if (!mounted) return;
    final ctrl = _controller;
    final nextEp = _lookupNextEpisode();
    if (ctrl == null || nextEp == null) return;

    final nextIdx = _currentEpisodeIndex! + 1;

    setState(() {
      _currentFilePath = nextEp.filePath;
      _currentEpisodeTitle = nextEp.fullDisplayName;
      _currentSubtitlePath = nextEp.subtitlePath;
      _currentEpisodeIndex = nextIdx;
      _currentMediaId = widget.mediaId != null
          ? '${widget.mediaId!.split('::').first}::${nextEp.filePath}'
          : null;
      _completionHandled = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });

    ctrl.replaceMedia(
      filePath: nextEp.filePath,
      subtitlePath: nextEp.subtitlePath,
      startPosition: Duration.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wichtig: Der UiKitView mit VLC's drawable-UIView schluckt alle
    // Touch-Events auf iOS weil `gestureRecognizers` leer ist. Ein
    // GestureDetector WRAPPER um den Stack kriegt die Taps auf den
    // Videobereich deshalb nie. Fix: transparenter Layer ÜBER dem
    // UiKitView als dedicated tap-catcher. Der liegt unter dem
    // Controls-Overlay (damit sichtbare Buttons weiterhin funktionieren)
    // und fängt alles ab was sonst in VLC verschwinden würde.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: IOSVLCPlayerView(
              filePath: widget.filePath,
              subtitlePath: widget.subtitlePath,
              startPosition: widget.startPosition,
              onReady: _onReady,
            ),
          ),

          // Transparenter Tap-Catcher. Nur aktiv wenn Controls gerade
          // ausgeblendet sind — sobald sie sichtbar sind, lässt er Taps
          // durchfallen damit die Buttons reagieren. `translucent`
          // (nicht `opaque`) damit Gesten die durch IgnorePointer der
          // Controls geblockt werden trotzdem hier ankommen.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _controlsVisible,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
              ),
            ),
          ),

          // Controls-Overlay — minimal: Play/Pause + Scrubber +
          // Close. Kein Volume (iOS Hardware-Tasten reichen), kein
          // Fullscreen-Toggle (sind ja schon vollflächig), kein
          // Speed-Picker (kommt später wenn nötig).
          AnimatedOpacity(
            opacity: _controlsVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              // GestureDetector um das Overlay selbst: Tap auf den
              // halbtransparenten Bereich (nicht auf Buttons) blendet
              // die Controls wieder aus. Symmetrisch zum Verhalten von
              // AVPlayerViewController.
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _toggleControls,
                child: _buildControlsOverlay(context),
              ),
            ),
          ),

          if (_playbackError != null)
            Positioned.fill(child: _buildErrorOverlay()),
        ],
      ),
    );
  }

  Widget _buildControlsOverlay(BuildContext context) {
    return Stack(
      children: [
        // Top-Bar: durchgehende Leiste am oberen Bildschirmrand, links
        // Close, mittig Titel (flexibel, Ellipsis), rechts PiP. Ein
        // gemeinsamer Gradient-Hintergrund damit's auf beliebigem
        // Video-Content lesbar bleibt ohne bunte Kästen pro Button.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 4,
              bottom: 8,
              left: 8,
              right: 8,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.75),
                ],
              ),
            ),
            child: SafeArea(
              top: false,
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 28),
                    tooltip: 'Schließen',
                    onPressed: () {
                      _saveProgress();
                      Navigator.of(context).pop();
                    },
                  ),
                  Expanded(
                    child: Text(
                      _currentEpisodeTitle ?? widget.title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(color: Colors.black, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _pipActive
                          ? Icons.picture_in_picture_alt_rounded
                          : Icons.picture_in_picture_rounded,
                      color: _pipAvailable
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.35),
                      size: 26,
                    ),
                    tooltip:
                        _pipActive ? 'PiP beenden' : 'Picture-in-Picture',
                    onPressed: _pipAvailable ? _togglePiP : null,
                  ),
                ],
              ),
            ),
          ),
        ),

        // Zentrierter Play/Pause-Button — groß, auf Bildmitte. Touch-
        // Target bleibt klein genug dass seitliche Taps zum Controls-
        // Toggle durchkommen (GestureDetector liegt hinter dem Button).
        Center(
          child: Material(
            color: Colors.black.withValues(alpha: 0.35),
            shape: const CircleBorder(),
            child: IconButton(
              iconSize: 72,
              padding: const EdgeInsets.all(12),
              icon: Icon(
                _isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
              ),
              onPressed: () {
                final c = _controller;
                if (c == null) return;
                if (_isPlaying) {
                  c.pause();
                } else {
                  c.play();
                }
                _scheduleControlsHide();
              },
            ),
          ),
        ),

        // Bottom-Bar: Progress + Zeitangaben. Play/Pause ist bewusst
        // NICHT mehr hier drin — wandert in die Mitte (Netflix/Apple TV
        // Layout). Nur noch Slider und Timestamps.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 24,
              bottom: MediaQuery.of(context).padding.bottom + 8,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.8),
                ],
              ),
            ),
            child: Row(
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16,
                      ),
                    ),
                    child: Slider(
                      value: _sliderValue(),
                      onChanged: (v) {
                        if (_duration.inMilliseconds <= 0) return;
                        setState(() {
                          _position = Duration(
                            milliseconds:
                                (v * _duration.inMilliseconds).round(),
                          );
                        });
                      },
                      onChangeEnd: (v) {
                        if (_duration.inMilliseconds <= 0) return;
                        final target = Duration(
                          milliseconds:
                              (v * _duration.inMilliseconds).round(),
                        );
                        _controller?.seek(target);
                        _scheduleControlsHide();
                      },
                      activeColor: AppTheme.accent,
                      inactiveColor: Colors.white24,
                    ),
                  ),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  double _sliderValue() {
    final d = _duration.inMilliseconds;
    if (d <= 0) return 0;
    return (_position.inMilliseconds / d).clamp(0.0, 1.0);
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  Widget _buildErrorOverlay() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.85),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.redAccent, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Wiedergabe nicht möglich',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _playbackError ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Zurück'),
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
