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

  // Seek-Koaleszenz: wenn der User schnell mehrmals ±10s drückt, kommt
  // die nächste position-Event aus VLC erst ~100ms später. Ohne
  // Koaleszenz benutzt der zweite Skip noch _position (pre-erster-Skip)
  // → landet wieder an der Ausgangsposition statt 20s weiter. Wir
  // merken uns die zuletzt angefragte Zielposition und rechnen weitere
  // Skips darauf drauf, solange VLC noch nicht bestätigt hat.
  Duration? _pendingSeekTarget;
  DateTime? _pendingSeekAt;

  // Slider-Scrubbing. Während true werden position-Events aus VLC
  // ignoriert (sonst springt der Daumen beim Ziehen kurz auf die
  // letzte bestätigte Position zurück), und der Auto-Hide-Timer ist
  // angehalten damit die Controls während des Seekens sichtbar bleiben.
  bool _isScrubbing = false;

  // Nur für Slider + Zeitangaben. Wird bei jedem VLC-Position-Event
  // geupdated ohne dass setState den ganzen Screen rebuildet — der
  // ValueListenableBuilder im Bottom-Bar rebuildet nur seinen Subtree.
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier(Duration.zero);

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

    // Orientation zurück auf Portrait-Lock (nicht DeviceOrientation.values)
    // — der Rest der App ist portrait-only, und wenn wir hier "alle
    // Orientations" zurückgeben würde der darüberliegende Home-Screen
    // kurz in Landscape rendern bis das System-Frame zurückfällt.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    _positionNotifier.dispose();
    _durationNotifier.dispose();

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

  /// Tap irgendwo auf den Bildschirm (weder auf einen konkreten Button
  /// noch auf den Countdown-Button). Wenn das Next-Episode-Overlay
  /// gerade angezeigt wird, gilt der Tap als "Abspann ansehen" und
  /// unterdrückt den Auto-Skip. Zusätzlich togglen wir wie bisher die
  /// Controls-Sichtbarkeit, damit der User nicht das Gefühl hat der Tap
  /// sei ins Leere gegangen.
  void _handleBackgroundTap() {
    if (_showNextEpisode && !_watchingCredits) {
      setState(() => _watchingCredits = true);
    }
    _toggleControls();
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
      // Während der User scrubt: Position-Events ignorieren, sonst
      // kämpft der Slider-Thumb mit VLC um den Ownership.
      if (_isScrubbing) return;
      // Pending-Seek-Koaleszenz: wenn wir selbst gerade einen Seek
      // rausgeschickt haben und VLC noch mit alter Position rein-
      // kommt, verwerfen. Fenster von 500ms deckt VLC's round-trip ab.
      if (_pendingSeekTarget != null && _pendingSeekAt != null) {
        final age = DateTime.now().difference(_pendingSeekAt!);
        final closeEnough = (pos.inMilliseconds -
                _pendingSeekTarget!.inMilliseconds)
            .abs();
        if (age < const Duration(milliseconds: 500) &&
            closeEnough > 1500) {
          return;
        }
        // VLC hat uns eingeholt — Pending-Marker löschen.
        _pendingSeekTarget = null;
        _pendingSeekAt = null;
      }
      // Position für _checkNearEnd + Skip-Base merken, aber ohne
      // setState — der Slider und die Zeitangaben rendern sich
      // separat via _positionNotifier (ValueListenableBuilder). Das
      // spart bei 10 Hz den kompletten Rebuild der Top-/Bottom-Bar,
      // der gefühlt als "ruckelig" beim Scrubben wahrnehmbar war.
      _position = pos;
      _positionNotifier.value = pos;
      _checkNearEnd(pos);
    });

    _durationSub = ctrl.durationStream.listen((dur) {
      if (!mounted) return;
      _duration = dur;
      _durationNotifier.value = dur;
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

  /// Orientation zurück auf Portrait-Lock (App-global). Muss VOR
  /// Navigator.pop() laufen, nicht erst in dispose() — sonst zeigt
  /// iOS den vorherigen Screen kurz (eine Animation lang) noch im
  /// erzwungenen Landscape bevor dispose ankommt.
  void _restoreOrientation() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
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
    // Basis ist entweder der letzte ungetroffene Seek-Target (wenn
    // einer in den letzten 500ms losgeschickt wurde) oder die aktuelle
    // Position. Ohne das kumuliert schnelles ±10s nicht sondern
    // springt immer um nur 10s vom selben Punkt.
    final now = DateTime.now();
    final base = (_pendingSeekTarget != null &&
            _pendingSeekAt != null &&
            now.difference(_pendingSeekAt!) <
                const Duration(milliseconds: 500))
        ? _pendingSeekTarget!
        : _position;
    final target = base + delta;
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(
        0,
        _duration.inMilliseconds > 0 ? _duration.inMilliseconds : (1 << 31),
      ),
    );
    _pendingSeekTarget = clamped;
    _pendingSeekAt = now;
    // Sofort visuell bestätigen — sonst wirkt der Button "tot" bis VLC
    // antwortet. Nur Notifier setzen, nicht setState → rebuild bleibt
    // auf Slider-Subtree beschränkt.
    _position = clamped;
    _positionNotifier.value = clamped;
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
      _positionNotifier.value = Duration.zero;
      _durationNotifier.value = Duration.zero;
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
                onTap: _handleBackgroundTap,
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
                onTap: _handleBackgroundTap,
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
        // Top-Bar: X + Serie/Folge links (Windows-Layout), rechts die
        // drei sekundären Controls (PiP, Untertitel, Audio) symmetrisch
        // angeordnet — alle 40×40 mit konstant 8px Abstand. Reihenfolge
        // links→rechts: PiP, Untertitel, Audio (damit "Audio" am Rand
        // sitzt, wie in Windows).
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 12,
              bottom: 18,
              left: 28,
              right: 28,
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
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(
                              blurRadius: 6,
                              color: Color(0xCC000000),
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                      if (_currentEpisodeTitle != null)
                        Text(
                          _currentEpisodeTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                            shadows: [
                              Shadow(
                                blurRadius: 6,
                                color: Color(0xCC000000),
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // Drei symmetrische rechte Buttons. Reihenfolge links→
                // rechts: Untertitel, Audio, PiP — PiP sitzt damit am
                // Rand (analog zum sekundären "special" Control in
                // Windows). Immer sichtbar, nur disabled wenn gerade
                // nicht verfügbar — so springt das Layout nicht.
                _buildEdgeIcon(
                  icon: Icons.subtitles_rounded,
                  tooltip: 'Untertitel',
                  enabled: _subtitleTracks.isNotEmpty,
                  onPressed: _subtitleTracks.isNotEmpty
                      ? () => _openSubtitleMenu(context)
                      : null,
                ),
                const SizedBox(width: 8),
                _buildEdgeIcon(
                  icon: Icons.chat_rounded,
                  tooltip: 'Audio-Spur',
                  enabled: _audioTracks.length > 1,
                  onPressed: _audioTracks.length > 1
                      ? () => _openAudioMenu(context)
                      : null,
                ),
                const SizedBox(width: 8),
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

        // Bottom-Bar: Progress + Zeitangaben, ganz rechts der
        // "nächste Folge"-Button (nur sichtbar wenn's eine gibt). Play/
        // Pause wandert in die Mitte (Netflix/Apple-TV-Layout).
        //
        // `bottom: 4` statt safeArea+8 — in Landscape ist der Home-
        // Indicator-Bereich minimal, der User hat explizit gesagt die
        // Leiste soll weiter unten sein.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.only(
              left: 28,
              right: 28,
              top: 28,
              bottom: 18,
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
            child: _buildScrubRow(context),
          ),
        ),
      ],
    );
  }

  /// Öffnet das Untertitel-Menü als unten-eingeblendete ModalBottom-
  /// Sheet-Variante mit eigenem dunklem Styling. Einheitlich für
  /// Touch-Geräte (auf iOS/iPad sind PopupMenus über IconButtons
  /// ergonomisch nicht toll — zu kleiner Anchor-Bereich, zu viel
  /// Movement vom Finger zum Menü).
  Future<void> _openSubtitleMenu(BuildContext context) async {
    _scheduleControlsHide();
    final chosen = await _showTrackMenu(
      context: context,
      title: 'Untertitel',
      tracks: _subtitleTracks,
    );
    if (chosen != null) {
      await _setSubtitleTrack(chosen);
    }
  }

  Future<void> _openAudioMenu(BuildContext context) async {
    _scheduleControlsHide();
    final chosen = await _showTrackMenu(
      context: context,
      title: 'Audio-Spur',
      tracks: _audioTracks,
    );
    if (chosen != null) {
      await _setAudioTrack(chosen);
    }
  }

  /// Gemeinsames Styling für beide Track-Menüs: dunkler Hintergrund,
  /// weiße Schrift, ausgewählter Eintrag rot mit Häkchen (kein Radio-
  /// Button — das hat der User explizit nicht gewollt).
  Future<int?> _showTrackMenu({
    required BuildContext context,
    required String title,
    required List<VlcTrack> tracks,
  }) {
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF121212),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
                ...tracks.map((t) {
                  final selected = t.isCurrent;
                  return InkWell(
                    onTap: () => Navigator.of(ctx).pop(t.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.check_rounded
                                : null,
                            size: 20,
                            color: selected
                                ? AppTheme.accent
                                : Colors.transparent,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              t.name,
                              style: TextStyle(
                                color: selected
                                    ? AppTheme.accent
                                    : Colors.white,
                                fontSize: 15,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 6),
              ],
            ),
          ),
        );
      },
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

  /// Minimales "Nächste Folge"-Overlay fürs Handy: nur ein einziger
  /// Button mit Fortschrittsfüllung. Der User tippt entweder den Button
  /// (→ sofort weiter) oder irgendwo anders auf den Screen (→ wird als
  /// "Abspann ansehen" gewertet und der Auto-Skip unterdrückt).
  /// Der Tap-außerhalb wird von `_handleOutsideNextEpisodeTap` in der
  /// Haupt-Stack unten abgefangen — dieser Widget rendert nur den Button
  /// selbst, ohne eigenen Tap-Blocker rundherum.
  Widget _buildNextEpisodeOverlay(BuildContext context) {
    final nextEp = _lookupNextEpisode();
    if (nextEp == null) return const SizedBox.shrink();
    return Positioned(
      right: 20,
      // Näher an der Bottom-Bar — der Button soll etwas weiter unten
      // sitzen als vorher (User-Feedback), aber immer noch komplett
      // über dem Scrubber bleiben.
      bottom: 68,
      child: AnimatedOpacity(
        opacity: (_showNextEpisode && !_watchingCredits) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: IgnorePointer(
          ignoring: !_showNextEpisode || _watchingCredits,
          child: SizedBox(
            width: 240,
            height: 48,
            child: _buildCountdownButton(),
          ),
        ),
      ),
    );
  }

  /// Countdown-Button — Hintergrund füllt sich grau von links nach
  /// rechts während die Restzeit läuft. Flüssige Animation via
  /// `TweenAnimationBuilder`: position-Events kommen nur alle ~200ms
  /// aus VLC, ohne Tween sieht man diskrete Sprünge. Der Builder tweent
  /// jede Änderung des `progress`-Werts über 280ms linear — das deckt
  /// das 200ms-Interval mit genug Overlap ab, sodass sich die Füllung
  /// visuell kontinuierlich bewegt.
  Widget _buildCountdownButton() {
    final progress = _countdownProgress;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: progress, end: progress),
        duration: const Duration(milliseconds: 280),
        curve: Curves.linear,
        builder: (ctx, value, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              Row(
                children: [
                  if (value > 0)
                    Expanded(
                      flex: (value * 1000).round().clamp(0, 1000),
                      child: Container(
                        color: const Color(0xFFBDBDBD),
                      ),
                    ),
                  Expanded(
                    flex: ((1.0 - value) * 1000).round().clamp(0, 1000),
                    child: Container(color: Colors.white),
                  ),
                ],
              ),
              // Material + InkWell bekommen Positioned.fill und ihr
              // Child ist Center, damit Icon+Text garantiert vertikal
              // mittig im 48px hohen Button sitzen. Davor lief das
              // über die Row's Intrinsic-Höhe und saß optisch am oberen
              // Rand.
              Positioned.fill(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      _completionHandled = true;
                      _saveProgress(treatAsCompleted: true);
                      _playNextEpisode();
                    },
                    child: const Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(Icons.play_arrow_rounded,
                              size: 22, color: Colors.black),
                          SizedBox(width: 6),
                          Text(
                            'Nächste Folge',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Baut Zeitangaben + Slider + (optional) Next-Episode-Icon.
  /// Rebuildet nur sich selbst bei Position-Updates (via Nested
  /// ValueListenableBuilder), nicht den gesamten Control-Overlay.
  /// Der große 56×56 Next-Episode-Icon sitzt rechts außen, deutlich
  /// größer als die Top-Bar-Buttons, wie User in 1.5.26 gewünscht.
  Widget _buildScrubRow(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: _durationNotifier,
      builder: (ctx, duration, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: _positionNotifier,
          builder: (ctx, position, _) {
            final dMs = duration.inMilliseconds;
            final value = dMs <= 0
                ? 0.0
                : (position.inMilliseconds / dMs).clamp(0.0, 1.0);
            return Row(
              children: [
                Text(
                  _formatDuration(position),
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
                        enabledThumbRadius: 8,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 18,
                      ),
                    ),
                    child: Slider(
                      value: value,
                      onChangeStart: (_) {
                        _controlsHideTimer?.cancel();
                        _isScrubbing = true;
                      },
                      onChanged: (v) {
                        if (duration.inMilliseconds <= 0) return;
                        // Nur den Notifier updaten → nur dieser Subtree
                        // rebuildet (Slider + Zeit-Text). Früher rief
                        // der Handler setState auf dem ganzen Screen
                        // auf, was die Top-Bar inkl. Gradients jedesmal
                        // rebuildete → spürbares Ruckeln.
                        _positionNotifier.value = Duration(
                          milliseconds:
                              (v * duration.inMilliseconds).round(),
                        );
                      },
                      onChangeEnd: (v) {
                        if (duration.inMilliseconds <= 0) return;
                        final target = Duration(
                          milliseconds:
                              (v * duration.inMilliseconds).round(),
                        );
                        _pendingSeekTarget = target;
                        _pendingSeekAt = DateTime.now();
                        _position = target;
                        _positionNotifier.value = target;
                        _controller?.seek(target);
                        _isScrubbing = false;
                        _scheduleControlsHide();
                      },
                      activeColor: AppTheme.accent,
                      inactiveColor: Colors.white24,
                    ),
                  ),
                ),
                Text(
                  _formatDuration(duration),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (_lookupNextEpisode() != null) ...[
                  const SizedBox(width: 12),
                  _buildNextEpisodeIcon(),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /// Größer als _buildEdgeIcon (56×56 statt 40×40), damit der
  /// Nächste-Folge-Button neben der Zeitangabe deutlich hervortritt
  /// — User-Feedback 1.5.26: der kleine 40er wirkte verloren.
  Widget _buildNextEpisodeIcon() {
    return SizedBox(
      width: 56,
      height: 56,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 36,
        tooltip: 'Nächste Folge',
        icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
        onPressed: () {
          _completionHandled = true;
          _saveProgress(treatAsCompleted: true);
          _playNextEpisode();
        },
      ),
    );
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
