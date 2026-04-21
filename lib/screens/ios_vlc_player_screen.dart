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

  // Verfügbare Tracks — werden nach Playback-Start via Plugin abgefragt
  // (MobileVLCKit kennt die erst, wenn der Decoder die Streams enumeriert
  // hat, daher zeitversetzt befüllen).
  List<VlcTrack> _audioTracks = const [];
  List<VlcTrack> _subtitleTracks = const [];

  // Next-Episode-Countdown. _showNextEpisode wird true wenn Position ≥ 95%
  // der Dauer (entsprechend player_screen.dart auf Windows). _watchingCredits
  // heißt: User hat explizit "Abspann ansehen" gedrückt → auto-skip aus.
  bool _showNextEpisode = false;
  bool _watchingCredits = false;

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

    // Orientation-Lock wieder aufheben als Safety Net — der
    // Standardpfad (X-Button) ruft _restoreOrientation vor dem pop()
    // auf, damit der Unlock noch in diesem Frame passiert. Falls der
    // User per iPad-Back-Geste rausgeht oder das System die Route
    // zerreißt, greift dieser dispose-Call.
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
      _checkNearEnd(pos);
    });

    _durationSub = ctrl.durationStream.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur);
      // Dauer kommt erst nach "playing"-State aus VLC — guter Moment
      // um Audio- und Untertitel-Spuren zu enumerieren (der Decoder
      // hat bis dahin alle Streams gesehen).
      _refreshTracks();
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

  /// Orientation-Lock explizit aufheben. Muss VOR Navigator.pop()
  /// laufen, nicht erst in dispose() — sonst zeigt iOS den vorherigen
  /// Screen kurz (eine Animation lang) noch im erzwungenen Landscape
  /// bevor dispose ankommt. dispose() hat denselben Call als Safety
  /// Net falls der User per Back-Geste (iPad) oder OS-Kill rausgeht.
  void _restoreOrientation() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  void _handleClose() {
    _saveProgress();
    _restoreOrientation();
    Navigator.of(context).pop();
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

  Future<void> _refreshTracks() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    try {
      final audio = await ctrl.getAudioTracks();
      final subs = await ctrl.getSubtitleTracks();
      if (!mounted) return;
      setState(() {
        _audioTracks = audio;
        _subtitleTracks = subs;
      });
    } catch (_) {
      // Nicht kritisch — User kommt ohne Dropdown-Menüs aus.
    }
  }

  /// Prüft ob wir uns den "nächste Folge"-Overlay anzeigen (95 %) und
  /// ob wir schon über die Auto-Skip-Schwelle (99.5 %) drüber sind.
  /// Gleiche Schwellen wie auf Windows (siehe player_screen.dart).
  void _checkNearEnd(Duration position) {
    if (_lookupNextEpisode() == null) return;
    if (_completionHandled) return;
    final totalMs = _duration.inMilliseconds;
    if (totalMs <= 30000) return;
    final remaining = 1.0 - (position.inMilliseconds / totalMs);
    if (remaining <= 0.05 && !_showNextEpisode) {
      setState(() => _showNextEpisode = true);
    }
    if (remaining <= 0.005 && !_watchingCredits && _showNextEpisode) {
      _completionHandled = true;
      _playNextEpisode();
    }
  }

  /// 0.0 (grad erschienen bei 5 % Rest) → 1.0 (Auto-Skip bei 0.5 %).
  /// Wird vom Countdown-Button als Fortschrittsanzeige benutzt.
  double get _countdownProgress {
    if (!_showNextEpisode || _watchingCredits) return 0.0;
    final totalMs = _duration.inMilliseconds;
    if (totalMs <= 0) return 0.0;
    final remaining = 1.0 - (_position.inMilliseconds / totalMs);
    return ((0.05 - remaining) / (0.05 - 0.005)).clamp(0.0, 1.0);
  }

  Future<void> _skipBy(Duration delta) async {
    final ctrl = _controller;
    if (ctrl == null) return;
    final target = _position + delta;
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(
        0,
        _duration.inMilliseconds > 0 ? _duration.inMilliseconds : (1 << 31),
      ),
    );
    await ctrl.seek(clamped);
    _scheduleControlsHide();
  }

  Future<void> _setAudioTrack(int id) async {
    await _controller?.setAudioTrack(id);
    await _refreshTracks();
  }

  Future<void> _setSubtitleTrack(int id) async {
    await _controller?.setSubtitleTrack(id);
    await _refreshTracks();
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
      // Countdown-Overlay für neue Folge zurücksetzen.
      _showNextEpisode = false;
      _watchingCredits = false;
      _audioTracks = const [];
      _subtitleTracks = const [];
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

          // Next-Episode-Overlay — außerhalb der AnimatedOpacity-Controls,
          // damit es auch dann sichtbar ist wenn die Haupt-Controls schon
          // auto-hidden sind (Netflix-Pattern).
          _buildNextEpisodeOverlay(context),

          if (_playbackError != null)
            Positioned.fill(child: _buildErrorOverlay()),
        ],
      ),
    );
  }

  Widget _buildControlsOverlay(BuildContext context) {
    return Stack(
      children: [
        // Top-Bar — Icons hängen flush am Rand (16px Inset wie die
        // Zeitangaben unten), Titel in der Mitte, Reihenfolge rechts:
        // Audio, Untertitel, PiP. SafeArea bewusst NICHT horizontal
        // benutzt, weil die iPhone-Notch-Insets sonst im Landscape
        // die Icons 40+px nach innen drücken — der User will die
        // aber am Rand haben.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 4,
              bottom: 12,
              left: 16,
              right: 16,
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
            child: Row(
              children: [
                _buildEdgeIcon(
                  icon: Icons.close_rounded,
                  tooltip: 'Schließen',
                  onPressed: _handleClose,
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
                if (_audioTracks.length > 1)
                  _buildAudioButton()
                else
                  const SizedBox(width: 0),
                if (_subtitleTracks.isNotEmpty)
                  _buildSubtitleButton()
                else
                  const SizedBox(width: 0),
                _buildEdgeIcon(
                  icon: _pipActive
                      ? Icons.picture_in_picture_alt_rounded
                      : Icons.picture_in_picture_rounded,
                  tooltip:
                      _pipActive ? 'PiP beenden' : 'Picture-in-Picture',
                  enabled: _pipAvailable,
                  onPressed: _pipAvailable ? _togglePiP : null,
                ),
              ],
            ),
          ),
        ),

        // Zentrale Transport-Controls: -10s, Play/Pause, +10s. Play
        // bleibt der rote AppTheme.accent-Kreis (Windows-Look), Skip-
        // Buttons sind dezenter (nur Icon auf halbtransparenter Scheibe)
        // damit der Fokus auf Play bleibt.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSkipButton(
                icon: Icons.replay_10_rounded,
                tooltip: '10 Sekunden zurück',
                onPressed: () => _skipBy(const Duration(seconds: -10)),
              ),
              const SizedBox(width: 32),
              GestureDetector(
                onTap: () {
                  final c = _controller;
                  if (c == null) return;
                  if (_isPlaying) {
                    c.pause();
                  } else {
                    c.play();
                  }
                  _scheduleControlsHide();
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(width: 32),
              _buildSkipButton(
                icon: Icons.forward_10_rounded,
                tooltip: '10 Sekunden vor',
                onPressed: () => _skipBy(const Duration(seconds: 10)),
              ),
            ],
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

  /// 40×40 Icon-Button ohne Inner-Padding — sitzt damit optisch flush
  /// am umgebenden Padding (left: 16 oder right: 16 der Top-Bar).
  /// Zentrales Tap-Target bleibt ein komfortables 40×40.
  Widget _buildEdgeIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool enabled = true,
  }) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        padding: EdgeInsets.zero,
        icon: Icon(
          icon,
          color: enabled
              ? Colors.white
              : Colors.white.withValues(alpha: 0.35),
          size: 26,
        ),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }

  Widget _buildSkipButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 32),
      ),
    );
  }

  Widget _buildAudioButton() {
    return PopupMenuButton<int>(
      tooltip: 'Audio-Spur',
      color: AppTheme.surface,
      icon: const Icon(Icons.audiotrack_rounded,
          color: Colors.white, size: 24),
      padding: EdgeInsets.zero,
      onSelected: _setAudioTrack,
      onOpened: _scheduleControlsHide,
      itemBuilder: (_) => [
        for (final t in _audioTracks)
          PopupMenuItem<int>(
            value: t.id,
            child: Row(
              children: [
                Icon(
                  t.isCurrent
                      ? Icons.check_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: t.isCurrent
                      ? AppTheme.accent
                      : AppTheme.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.name,
                    style: TextStyle(
                      color: t.isCurrent
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontWeight:
                          t.isCurrent ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSubtitleButton() {
    return PopupMenuButton<int>(
      tooltip: 'Untertitel',
      color: AppTheme.surface,
      icon: const Icon(Icons.subtitles_rounded,
          color: Colors.white, size: 24),
      padding: EdgeInsets.zero,
      onSelected: _setSubtitleTrack,
      onOpened: _scheduleControlsHide,
      itemBuilder: (_) => [
        for (final t in _subtitleTracks)
          PopupMenuItem<int>(
            value: t.id,
            child: Row(
              children: [
                Icon(
                  t.isCurrent
                      ? Icons.check_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: t.isCurrent
                      ? AppTheme.accent
                      : AppTheme.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.name,
                    style: TextStyle(
                      color: t.isCurrent
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontWeight:
                          t.isCurrent ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// "Nächste Folge"-Overlay mit Countdown-Button — rechts unten
  /// eingeblendet ab 95 % Fortschritt. Klick auf den Button startet
  /// sofort die nächste Folge, "Abspann ansehen" unterdrückt den
  /// Auto-Skip. Bei 99.5 % feuert `_checkNearEnd` den Auto-Skip
  /// wenn `_watchingCredits` nicht gesetzt ist.
  Widget _buildNextEpisodeOverlay(BuildContext context) {
    final nextEp = _lookupNextEpisode();
    if (nextEp == null) return const SizedBox.shrink();
    return Positioned(
      bottom: 110,
      right: 24,
      child: AnimatedOpacity(
        opacity: _showNextEpisode ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: IgnorePointer(
          ignoring: !_showNextEpisode,
          child: Container(
            width: 300,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.accent.withValues(alpha: 0.3),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.skip_next_rounded,
                        color: AppTheme.accent, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      _watchingCredits
                          ? 'Nächste Folge nach dem Abspann'
                          : 'Nächste Folge',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  nextEp.fullDisplayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                if (!_watchingCredits) ...[
                  _buildCountdownButton(),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        setState(() => _watchingCredits = true);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textSecondary,
                        side: const BorderSide(
                            color: AppTheme.textMuted, width: 1),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text('Abspann ansehen',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
                if (_watchingCredits)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        _completionHandled = true;
                        _playNextEpisode();
                      },
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: const Text('Jetzt abspielen'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Button, dessen Hintergrund von links nach rechts grau füllt
  /// während der Countdown läuft (0 → 1). Analog zum Windows-Player.
  Widget _buildCountdownButton() {
    final progress = _countdownProgress;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: double.infinity,
        height: 38,
        child: Stack(
          children: [
            Positioned.fill(
              child: Row(
                children: [
                  if (progress > 0)
                    Expanded(
                      flex: (progress * 1000).round().clamp(0, 1000),
                      child: Container(color: const Color(0xFFBDBDBD)),
                    ),
                  Expanded(
                    flex: ((1.0 - progress) * 1000).round().clamp(0, 1000),
                    child: Container(color: Colors.white),
                  ),
                ],
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  _completionHandled = true;
                  _playNextEpisode();
                },
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_arrow_rounded,
                        size: 18, color: Colors.black),
                    SizedBox(width: 6),
                    Text(
                      'Nächste Folge',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
