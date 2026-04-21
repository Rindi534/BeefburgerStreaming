import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../models/episode.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../services/export_service.dart';
import '../services/fullscreen_service.dart';
import '../services/thumbnail_service.dart';
import 'settings_screen.dart';
import 'ios_player_screen.dart';

/// Platform-dispatching player entry point.
///
/// On Windows (and any desktop build) this returns the full
/// media_kit-based player with our custom chrome — unchanged from the
/// pre-iOS codebase. On iOS/iPadOS it returns a thin wrapper around
/// the native AVPlayerViewController bridge, which gives us system
/// PiP, AirPlay and scrub-previews for free.
///
/// All call sites keep using `PlayerScreen(...)` — they don't need to
/// know about the split.
class PlayerScreen extends StatelessWidget {
  final String filePath;
  final String title;
  final String? episodeTitle;
  final String? mediaId;
  final String? coverImagePath;
  final String? subtitlePath;
  final String? nextEpisodeFilePath;
  final String? nextEpisodeTitle;
  final String? nextEpisodeSubtitlePath;
  final Duration? startPosition;
  final List<Episode>? allEpisodes;
  final int? currentEpisodeIndex;

  const PlayerScreen({
    super.key,
    required this.filePath,
    required this.title,
    this.episodeTitle,
    this.mediaId,
    this.coverImagePath,
    this.subtitlePath,
    this.nextEpisodeFilePath,
    this.nextEpisodeTitle,
    this.nextEpisodeSubtitlePath,
    this.startPosition,
    this.allEpisodes,
    this.currentEpisodeIndex,
  });

  /// File extensions that AVPlayer (iOS system player) cannot decode
  /// natively. For these we fall back to the media_kit/libmpv-based
  /// desktop player on iOS — users lose PiP + AirPlay for those files
  /// but at least they play at all. MP4/MOV/M4V keep going through the
  /// native path so the PiP story stays intact for well-behaved files.
  static const _avPlayerUnsupported = {'.mkv', '.avi', '.iso', '.wmv', '.flv'};

  bool get _useDesktopFallbackOnIOS {
    final lower = filePath.toLowerCase();
    for (final ext in _avPlayerUnsupported) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS && !_useDesktopFallbackOnIOS) {
      return IOSPlayerScreen(
        filePath: filePath,
        title: title,
        episodeTitle: episodeTitle,
        mediaId: mediaId,
        subtitlePath: subtitlePath,
        nextEpisodeFilePath: nextEpisodeFilePath,
        nextEpisodeTitle: nextEpisodeTitle,
        nextEpisodeSubtitlePath: nextEpisodeSubtitlePath,
        startPosition: startPosition,
        allEpisodes: allEpisodes,
        currentEpisodeIndex: currentEpisodeIndex,
      );
    }
    return _DesktopPlayerScreen(
      filePath: filePath,
      title: title,
      episodeTitle: episodeTitle,
      mediaId: mediaId,
      coverImagePath: coverImagePath,
      subtitlePath: subtitlePath,
      nextEpisodeFilePath: nextEpisodeFilePath,
      nextEpisodeTitle: nextEpisodeTitle,
      nextEpisodeSubtitlePath: nextEpisodeSubtitlePath,
      startPosition: startPosition,
      allEpisodes: allEpisodes,
      currentEpisodeIndex: currentEpisodeIndex,
    );
  }
}

/// Desktop (Windows / macOS / Linux) implementation. Full media_kit
/// player with our custom Flutter chrome. This is the original
/// PlayerScreen — renamed so the public `PlayerScreen` above can
/// platform-dispatch without changing call sites.
class _DesktopPlayerScreen extends ConsumerStatefulWidget {
  final String filePath;
  final String title;
  final String? episodeTitle;
  final String? mediaId;
  final String? coverImagePath;
  final String? subtitlePath;
  final String? nextEpisodeFilePath;
  final String? nextEpisodeTitle;
  final String? nextEpisodeSubtitlePath;
  final Duration? startPosition;
  /// Full episode list for chained next-episode navigation
  final List<Episode>? allEpisodes;
  /// Index of current episode in allEpisodes
  final int? currentEpisodeIndex;

  const _DesktopPlayerScreen({
    required this.filePath,
    required this.title,
    this.episodeTitle,
    this.mediaId,
    this.coverImagePath,
    this.subtitlePath,
    this.nextEpisodeFilePath,
    this.nextEpisodeTitle,
    this.nextEpisodeSubtitlePath,
    this.startPosition,
    this.allEpisodes,
    this.currentEpisodeIndex,
  });

  @override
  ConsumerState<_DesktopPlayerScreen> createState() => _DesktopPlayerScreenState();
}

class _DesktopPlayerScreenState extends ConsumerState<_DesktopPlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;

  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _progressTimer;
  bool _subtitlesEnabled = true;
  bool _showNextEpisode = false;
  bool _watchingCredits = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;
  List<SubtitleTrack> _subtitleTracks = [];
  SubtitleTrack? _activeSubtitleTrack;
  List<AudioTrack> _audioTracks = [];
  AudioTrack? _activeAudioTrack;
  bool _seekDragging = false;
  double _seekValue = 0;
  bool _isFullscreen = false;
  bool _navigatingToNext = false;
  // Set when the file can't be opened / playback errors out. Triggers a
  // user-friendly overlay instead of a silent black screen.
  String? _playbackError;
  // Seekbar hover preview
  double? _hoverX;
  double _seekbarWidth = 0;
  Duration? _hoverTime;
  String? _hoverThumbnailPath;
  int? _hoverThumbnailIndex;

  // Clip export — two-click workflow: first click stores the start position
  // and puts the user into "clip mode" (shows a marker on the seekbar + the
  // video icon swaps to a "stop recording" style). Second click captures the
  // end position and opens the filename dialog. Both markers remain visible
  // through the filename dialog and the subsequent ffmpeg export so the user
  // keeps a visual reference of the clip range while it's being saved.
  Duration? _clipStart;
  Duration? _clipEnd;
  // True while an export (screenshot OR clip) is in flight. Blocks repeated
  // clicks so the user can't queue a second ffmpeg run before the first
  // finishes (which would deadlock on the same output filename).
  bool _isExporting = false;
  // True while the mouse is hovering over the bottom control bar (seekbar +
  // button row). Auto-hide is suppressed while this is true so the user can
  // read timestamps / press the clip button a second time without the UI
  // ducking away underneath them.
  bool _mouseOverControls = false;

  // --- Volume / mute state ----------------------------------------------
  // media_kit's Player takes volume in 0–100 range (not 0–1). We keep our
  // own mirror so hover slider + keyboard shortcuts share the same source
  // of truth without a Player event round-trip.
  double _volume = 100.0;
  bool _isMuted = false;
  // Volume at the moment the user hit mute, so toggling mute off restores
  // exactly where they were (not a hard-coded default).
  double _volumeBeforeMute = 100.0;
  // True while mouse is over the speaker icon OR the slider popup — we
  // keep the slider visible in both so a user doesn't lose it while
  // moving the cursor between icon and thumb.
  bool _volumeHovered = false;
  // Separate "pinned open" flag used when the user triggers volume via
  // keyboard (Arrow Up/Down, M). Lets the slider briefly appear even
  // though the cursor isn't near it, so the change is visible. Auto-
  // clears via _volumeKeyboardTimer.
  bool _volumeKeyboardShow = false;
  // Delayed hide after mouse-exit. Gives the user a generous window to
  // move the cursor from the icon onto the slider without the popup
  // snapping shut between them.
  Timer? _volumeHideTimer;
  // Auto-hide timer for the keyboard-triggered overlay.
  Timer? _volumeKeyboardTimer;
  // OverlayPortal machinery for the volume popup. We moved away from an
  // in-Stack `Positioned` because a Positioned child that paints OUTSIDE
  // its Stack's bounds receives paint but NOT hit tests — meaning the
  // user couldn't actually hover onto the slider without the popup
  // vanishing. An overlay child lives in its own layer and receives
  // pointer events normally, so hovering between icon and slider is
  // seamless. LayerLink keeps the popup positioned relative to the
  // icon as the toolbar reflows.
  final OverlayPortalController _volumeOverlayCtrl =
      OverlayPortalController();
  final LayerLink _volumeLink = LayerLink();
  // Tracks the last subtitle track the user actively chose. Used so the
  // "C" shortcut (and the combined subtitles dropdown) can toggle back to
  // the user's previous choice rather than always jumping to tracks[0].
  SubtitleTrack? _lastChosenSubtitleTrack;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _subtitlesEnabled = ref.read(settingsProvider).subtitlesEnabled;
    _isFullscreen = FullscreenService.isFullscreen;
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    // Pre-flight: verify the file is still there. Covers the "external drive
    // unplugged between library scan and user tapping Play" case with a clear
    // message instead of a hang or black screen.
    if (!await File(widget.filePath).exists()) {
      if (mounted) {
        setState(() {
          _playbackError =
              'Datei nicht gefunden:\n${widget.filePath}\n\nWurde die Datei verschoben oder die Festplatte getrennt?';
        });
      }
      return;
    }

    // mpv emits errors here for unsupported codecs, corrupt files, sudden
    // file loss during playback, etc. We surface these to the user rather
    // than leaving a silent buffering indicator forever.
    //
    // BUT: mpv also emits *transient, non-fatal* decode warnings through
    // the same channel — especially on .iso/DVD images where a single
    // audio frame fails but playback continues fine. Treating those as
    // fatal produced the "Error decoding audio" overlay while the video
    // happily played on in the background. So we verify: after a short
    // delay, check whether the position has actually advanced. If yes,
    // the error was cosmetic and we swallow it.
    _player.stream.error.listen((err) async {
      if (!mounted || err.isEmpty) return;
      if (_playbackError != null) return; // already showing a fatal one
      final before = _position;
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted || _playbackError != null) return;
      final stillAdvancing = _position > before + const Duration(milliseconds: 200);
      if (stillAdvancing) return; // transient decode warning — ignore
      setState(() {
        _playbackError =
            'Wiedergabe-Fehler:\n$err\n\nDie Datei ist möglicherweise beschädigt oder verwendet ein nicht unterstütztes Format.';
      });
    });

    // Listen to player state
    _player.stream.position.listen((pos) {
      if (!_seekDragging && mounted) {
        setState(() => _position = pos);
        _checkNearEnd(pos);
      }
    });

    _player.stream.duration.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });

    _player.stream.playing.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });

    _player.stream.buffering.listen((buffering) {
      if (mounted) setState(() => _isBuffering = buffering);
    });

    // When video ends completely: auto-play next if watching credits
    _player.stream.completed.listen((completed) {
      if (completed &&
          mounted &&
          _watchingCredits &&
          widget.nextEpisodeFilePath != null &&
          !_isCompleted) {
        _isCompleted = true;
        _playNextEpisode();
      }
    });

    _player.stream.tracks.listen((tracks) {
      if (mounted) {
        setState(() {
          _subtitleTracks = tracks.subtitle
              .where((t) => t.id != 'auto' && t.id != 'no')
              .toList();
          _audioTracks = tracks.audio
              .where((t) => t.id != 'auto' && t.id != 'no')
              .toList();
        });
      }
    });

    _player.stream.track.listen((track) {
      if (mounted) {
        setState(() {
          _activeSubtitleTrack = track.subtitle;
          _activeAudioTrack = track.audio;
        });
      }
    });

    _player.stream.completed.listen((completed) {
      if (completed && mounted) {
        setState(() => _isCompleted = true);
        _saveProgress();
      }
    });

    // Open media
    await _player.open(Media(widget.filePath));

    // Set external subtitle if available
    if (widget.subtitlePath != null) {
      final subFile = File(widget.subtitlePath!);
      if (await subFile.exists()) {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(widget.subtitlePath!),
        );
      }
    }

    // Seek to start position if resuming
    if (widget.startPosition != null &&
        widget.startPosition!.inSeconds > 0) {
      await Future.delayed(const Duration(milliseconds: 300));
      await _player.seek(widget.startPosition!);
    }

    // Handle subtitles initial state
    if (!_subtitlesEnabled) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    }

    // Start progress saving timer
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );

    _startHideTimer();
  }

  void _checkNearEnd(Duration position) {
    if (_duration.inSeconds < 30) return;
    if (widget.nextEpisodeFilePath == null) return;
    if (_isCompleted) return;

    final totalMs = _duration.inMilliseconds;
    final posMs = position.inMilliseconds;
    if (totalMs <= 0) return;

    final progressPercent = posMs / totalMs;
    final remainingPercent = 1.0 - progressPercent;

    // Show overlay at ~5% remaining
    if (remainingPercent <= 0.05 && !_showNextEpisode) {
      setState(() => _showNextEpisode = true);
    }

    // Auto-play at ~0.5% remaining (unless user chose to watch credits)
    if (remainingPercent <= 0.005 && !_watchingCredits && _showNextEpisode) {
      _isCompleted = true;
      _playNextEpisode();
    }
  }

  Future<void> _playNextEpisode() async {
    if (widget.nextEpisodeFilePath == null) return;

    _saveProgress();
    await _player.stop();

    if (!mounted) return;

    // Compute next-next episode info from the episode list
    String? nextNextFilePath;
    String? nextNextTitle;
    String? nextNextSubtitlePath;
    List<Episode>? allEpisodes = widget.allEpisodes;
    int? nextIndex;

    if (allEpisodes != null && widget.currentEpisodeIndex != null) {
      nextIndex = widget.currentEpisodeIndex! + 1;
      if (nextIndex + 1 < allEpisodes.length) {
        final nextNext = allEpisodes[nextIndex + 1];
        nextNextFilePath = nextNext.filePath;
        nextNextTitle = nextNext.fullDisplayName;
        nextNextSubtitlePath = nextNext.subtitlePath;
      }
    }

    _navigatingToNext = true;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          filePath: widget.nextEpisodeFilePath!,
          title: widget.title,
          episodeTitle: widget.nextEpisodeTitle,
          mediaId: widget.mediaId,
          coverImagePath: widget.coverImagePath,
          subtitlePath: widget.nextEpisodeSubtitlePath,
          nextEpisodeFilePath: nextNextFilePath,
          nextEpisodeTitle: nextNextTitle,
          nextEpisodeSubtitlePath: nextNextSubtitlePath,
          allEpisodes: allEpisodes,
          currentEpisodeIndex: nextIndex,
        ),
      ),
    );
  }

  void _saveProgress() {
    if (_position.inSeconds < 3 || _duration.inSeconds < 10) return;

    ref.read(watchProgressProvider.notifier).updateProgress(
          mediaId: widget.mediaId ?? widget.filePath,
          filePath: widget.filePath,
          position: _position,
          totalDuration: _duration,
          mediaTitle: widget.title,
          episodeTitle: widget.episodeTitle,
          coverImagePath: widget.coverImagePath,
        );

    final progressPercent = _position.inMilliseconds /
        (_duration.inMilliseconds == 0 ? 1 : _duration.inMilliseconds);

    if (progressPercent > 0.9) {
      if (widget.nextEpisodeFilePath != null) {
        // Queue next episode in "Weiterschauen"
        _queueNextEpisode();
      } else if (_isLastEpisode) {
        // Last episode of the entire series — reset all progress
        final allFilePaths =
            widget.allEpisodes?.map((e) => e.filePath).toList();
        ref.read(watchProgressProvider.notifier).clearProgressByMediaId(
              widget.mediaId ?? widget.filePath,
              episodeFilePaths: allFilePaths,
            );
      }
    }
  }

  void _queueNextEpisode() {
    if (widget.nextEpisodeFilePath == null) return;

    // Save next episode at position zero so it appears in "Weiterschauen"
    ref.read(watchProgressProvider.notifier).updateProgress(
          mediaId: widget.mediaId ?? widget.nextEpisodeFilePath!,
          filePath: widget.nextEpisodeFilePath!,
          position: Duration.zero,
          totalDuration: const Duration(minutes: 1), // placeholder
          mediaTitle: widget.title,
          episodeTitle: widget.nextEpisodeTitle,
          coverImagePath: widget.coverImagePath,
        );
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      // Don't hide while the user is hovering the bottom bar — they're
      // probably about to click something (e.g. mark a clip end point).
      if (_mouseOverControls) {
        _startHideTimer();
        return;
      }
      if (_isPlaying) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _startHideTimer();
  }

  void _toggleSubtitles() async {
    setState(() => _subtitlesEnabled = !_subtitlesEnabled);

    if (_subtitlesEnabled) {
      // Prefer the last track the user actively picked from the dropdown.
      // Falls back to the first available track, then to the external .srt
      // sidecar — same order as before, just with "remember my choice"
      // layered on top so C doesn't keep resetting the selection.
      final track = _lastChosenSubtitleTrack ??
          (_subtitleTracks.isNotEmpty ? _subtitleTracks.first : null);
      if (track != null) {
        await _player.setSubtitleTrack(track);
      } else if (widget.subtitlePath != null) {
        await _player.setSubtitleTrack(
          SubtitleTrack.uri(widget.subtitlePath!),
        );
      }
    } else {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    }
  }

  void _cycleAudioTrack() {
    if (_audioTracks.length <= 1) return;
    final currentIndex = _audioTracks.indexWhere(
      (t) => t.id == _activeAudioTrack?.id,
    );
    final nextIndex = (currentIndex + 1) % _audioTracks.length;
    final nextTrack = _audioTracks[nextIndex];
    _player.setAudioTrack(nextTrack);
  }

  // ---------------------------------------------------------------------
  // Volume / mute
  // ---------------------------------------------------------------------

  /// Applies a new volume value, clamped into the valid 0–100 range that
  /// media_kit expects. Centralized so the hover slider, keyboard arrows
  /// and unmute-restore all go through one path — no drift between them.
  Future<void> _setVolume(double newVolume) async {
    final clamped = newVolume.clamp(0.0, 100.0);
    await _player.setVolume(clamped);
    if (!mounted) return;
    setState(() {
      _volume = clamped;
      // Moving the slider away from zero implicitly un-mutes. Otherwise
      // a user "dragging up from mute" would hear nothing even though
      // the slider moved.
      if (_isMuted && clamped > 0) {
        _isMuted = false;
      }
    });
  }

  /// Bumps the volume by a single step (5%). Also serves as the implicit
  /// un-mute path when the user presses Arrow Up while muted.
  Future<void> _stepVolume(double delta) async {
    // Flash the slider overlay so the user can see the change — key
    // feedback for keyboard-driven adjustments.
    _flashVolumeOverlay();
    // Arrow-up while muted: restore to saved volume + step, so a tap on
    // the volume key always produces audible feedback rather than the
    // user wondering why nothing happened.
    if (_isMuted && delta > 0) {
      await _setVolume(_volumeBeforeMute + delta);
      return;
    }
    await _setVolume(_volume + delta);
  }

  /// Briefly reveals the volume slider overlay via a keyboard-triggered
  /// path (arrows, M). Independent of mouse hover so the user actually
  /// sees what they just changed.
  void _flashVolumeOverlay() {
    if (!mounted) return;
    setState(() => _volumeKeyboardShow = true);
    _showVolumeOverlay();
    _volumeKeyboardTimer?.cancel();
    _volumeKeyboardTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _volumeKeyboardShow = false);
      _syncVolumeOverlay();
    });
  }

  /// Delayed hide on hover-exit. A fixed 400ms grace period lets the
  /// cursor travel between icon and slider without flickering the popup
  /// closed — the older version hid immediately and made it near-
  /// impossible to land on the slider.
  void _scheduleVolumeHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      setState(() => _volumeHovered = false);
      _syncVolumeOverlay();
    });
  }

  void _cancelVolumeHide() {
    _volumeHideTimer?.cancel();
    if (!_volumeHovered) {
      setState(() => _volumeHovered = true);
    }
    _showVolumeOverlay();
  }

  void _showVolumeOverlay() {
    if (!_volumeOverlayCtrl.isShowing) _volumeOverlayCtrl.show();
  }

  /// Syncs the overlay visibility to the combined state flags. Called
  /// from timer callbacks where either flag might have just flipped to
  /// false — we only hide if BOTH are false so a mouse-exit mid-flash
  /// (or vice versa) doesn't snap the slider away prematurely.
  void _syncVolumeOverlay() {
    final shouldShow = _volumeHovered || _volumeKeyboardShow;
    if (shouldShow && !_volumeOverlayCtrl.isShowing) {
      _volumeOverlayCtrl.show();
    } else if (!shouldShow && _volumeOverlayCtrl.isShowing) {
      _volumeOverlayCtrl.hide();
    }
  }

  Future<void> _toggleMute() async {
    if (_isMuted) {
      // Un-mute → restore the volume we captured when entering mute.
      await _player.setVolume(_volumeBeforeMute);
      if (!mounted) return;
      setState(() {
        _isMuted = false;
        _volume = _volumeBeforeMute;
      });
    } else {
      // Remember where we were so unmute doesn't snap to a default.
      _volumeBeforeMute = _volume > 0 ? _volume : 100.0;
      await _player.setVolume(0);
      if (!mounted) return;
      setState(() {
        _isMuted = true;
      });
    }
  }

  /// Gates screenshot / clip buttons and their 1/2/P shortcuts. Reads
  /// directly from the settings provider every call — cheap (just a
  /// map lookup on a small state object) and ensures toggling the
  /// setting in another screen takes effect on the very next event
  /// without needing a rebuild signal routed into the player.
  bool get _advancedEnabled =>
      ref.read(settingsProvider).advancedToolsEnabled;

  /// Icon that reflects the current volume level (+ mute state). Matches
  /// platform conventions: muted → crossed-out speaker, high volume →
  /// speaker with waves, lower volumes → fewer waves, silent → just the
  /// speaker body.
  IconData get _volumeIcon {
    if (_isMuted || _volume <= 0) return Icons.volume_off_rounded;
    if (_volume < 35) return Icons.volume_mute_rounded;
    if (_volume < 70) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  Future<void> _toggleFullscreen() async {
    await FullscreenService.toggle();
    if (mounted) {
      setState(() => _isFullscreen = FullscreenService.isFullscreen);
    }
  }

  Future<void> _stopAndGoBack() async {
    _saveProgress();
    await _player.stop();
    if (FullscreenService.isFullscreen) {
      await FullscreenService.exitFullscreen();
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _saveProgress();
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _volumeHideTimer?.cancel();
    _volumeKeyboardTimer?.cancel();
    // Only exit fullscreen if NOT navigating to next episode
    if (FullscreenService.isFullscreen && !_navigatingToNext) {
      FullscreenService.exitFullscreen();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stopAndGoBack();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKeyEvent: _handleKeyEvent,
        child: MouseRegion(
          onHover: (_) {
            if (!_controlsVisible) _showControls();
          },
          child: GestureDetector(
            onTap: () {
              if (_controlsVisible) {
                setState(() => _controlsVisible = false);
              } else {
                _showControls();
              }
            },
            onDoubleTap: () {
              if (_isPlaying) {
                _player.pause();
              } else {
                _player.play();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video
                Video(
                  controller: _videoController,
                  controls: NoVideoControls,
                  subtitleViewConfiguration:
                      const SubtitleViewConfiguration(
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(
                          blurRadius: 8,
                          color: Colors.black,
                          offset: Offset(1, 1),
                        ),
                        Shadow(
                          blurRadius: 16,
                          color: Colors.black,
                        ),
                      ],
                    ),
                    padding: EdgeInsets.only(bottom: 80),
                  ),
                ),

                // Buffering indicator
                if (_isBuffering)
                  const Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.accent,
                    ),
                  ),

                // Controls overlay
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _buildControls(),
                  ),
                ),

                // Next episode overlay
                if (_showNextEpisode) _buildNextEpisodeOverlay(),

                // Playback error overlay — takes precedence, stops controls
                // from being useful anyway.
                if (_playbackError != null) _buildErrorOverlay(),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildControls() {
    return Container(
      // Netflix/Disney+-Style: very soft, long gradient instead of a
      // sharp "bar". Starts higher up (~50% from the bottom) and only
      // reaches ~60 % opacity at the very edge, so it reads as a
      // subtle vignette rather than a visible band. Icons/text carry
      // their own shadows (see _shadowed(…) helpers below) as a
      // belt-and-suspenders safety net on fully-white scenes.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x99000000), // top vignette — ~60 %
            Colors.transparent,
            Colors.transparent,
            Color(0x99000000), // bottom vignette — ~60 %
          ],
          stops: [0.0, 0.25, 0.5, 1.0],
        ),
      ),
      // Don't inset bottom — on Windows (non-fullscreen) SafeArea
      // reserves a small system gesture area at the bottom which
      // shows up as a black band under the control bar and clips
      // the bottom of the IconButton hover splashes. We handle
      // bottom spacing ourselves via the control row's padding.
      child: SafeArea(
        bottom: false,
        // Apply a subtle black halo to EVERY icon and text inside the
        // controls overlay. The gradient alone isn't enough on fully
        // white frames (snow, bright logos, etc.) — this ensures the
        // icons always read clearly. Cheap (GPU just paints a blurred
        // copy behind each glyph) and matches what Netflix et al. do.
        child: IconTheme.merge(
          data: const IconThemeData(
            shadows: [
              Shadow(
                blurRadius: 6,
                color: Color(0xCC000000),
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 28,
                      shadows: [
                        Shadow(
                            blurRadius: 6,
                            color: Color(0xCC000000),
                            offset: Offset(0, 1)),
                      ],
                    ),
                    onPressed: _stopAndGoBack,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(
                                  blurRadius: 6,
                                  color: Color(0xCC000000),
                                  offset: Offset(0, 1)),
                            ],
                          ),
                        ),
                        if (widget.episodeTitle != null)
                          Text(
                            widget.episodeTitle!,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              shadows: [
                                Shadow(
                                    blurRadius: 6,
                                    color: Color(0xCC000000),
                                    offset: Offset(0, 1)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Center play button
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Rewind 10s
                  IconButton(
                    icon: const Icon(Icons.replay_10_rounded,
                        color: Colors.white, size: 36),
                    onPressed: () {
                      final newPos = _position - const Duration(seconds: 10);
                      _player.seek(newPos < Duration.zero
                          ? Duration.zero
                          : newPos);
                    },
                  ),
                  const SizedBox(width: 32),
                  // Play/Pause
                  GestureDetector(
                    onTap: () {
                      if (_isPlaying) {
                        _player.pause();
                      } else {
                        _player.play();
                      }
                      _startHideTimer();
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
                  // Forward 10s
                  IconButton(
                    icon: const Icon(Icons.forward_10_rounded,
                        color: Colors.white, size: 36),
                    onPressed: () {
                      final newPos = _position + const Duration(seconds: 10);
                      _player.seek(
                          newPos > _duration ? _duration : newPos);
                    },
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Bottom bar: seek + controls. Wrapped in a MouseRegion so
            // auto-hide stays paused while the user is interacting with /
            // reading the seekbar or buttons.
            MouseRegion(
              onEnter: (_) => _mouseOverControls = true,
              onExit: (_) {
                _mouseOverControls = false;
                // Restart the hide countdown from now so the bar doesn't
                // vanish instantly when the mouse moves away.
                if (_isPlaying) _startHideTimer();
              },
              child: Padding(
              // Keep a little extra room at the bottom so IconButton
              // hover circles (~48 px) don't clip against the window
              // edge — previously 8 which cut the splash in half.
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Column(
                children: [
                  // Inline clip-in-progress banner — non-blocking, sits
                  // above the seek bar. Replaces what used to be a
                  // SnackBar (which covered the clip button and made the
                  // second-click-to-finish interaction impossible).
                  //
                  // Only shown between the first and second click (start
                  // set, end not yet set). Once the end is marked, the
                  // selection is complete and the user's attention moves
                  // to the filename dialog / export-progress snackbar —
                  // keeping the "klicke erneut für Endpunkt" hint around
                  // at that point would just be noise.
                  if (_clipStart != null && _clipEnd == null)
                    _buildClipInfoPill(),

                  // Seek bar with hover preview
                  _buildSeekBar(),

                  // Bottom control row. Layout is a Stack so the
                  // Screenshot+Clip pair can sit at the exact horizontal
                  // center (aligned with the big Play button above it)
                  // regardless of how wide the timestamp or right-side
                  // icon group grows. Using Spacers alone couldn't do
                  // that — two Spacers only center the middle if the
                  // left and right outer groups are the same width.
                  _buildBottomControlRow(),
                ],
              ),
            ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  /// True if this is the last episode of the entire series (last season, last episode)
  bool get _isLastEpisode {
    if (widget.allEpisodes == null || widget.currentEpisodeIndex == null) {
      return false;
    }
    return widget.currentEpisodeIndex == widget.allEpisodes!.length - 1;
  }

  /// Returns countdown progress 0.0 (just appeared at 5%) to 1.0 (auto-skip at 0.5%)
  double get _countdownProgress {
    if (!_showNextEpisode || _watchingCredits) return 0.0;
    final totalMs = _duration.inMilliseconds;
    if (totalMs <= 0) return 0.0;
    final remaining = 1.0 - (_position.inMilliseconds / totalMs);
    // Map 5% → 0.0, 0.5% → 1.0
    return ((0.05 - remaining) / (0.05 - 0.005)).clamp(0.0, 1.0);
  }

  /// Bottom control row with symmetric Screenshot/Clip placement.
  ///
  /// Layout rationale:
  /// - Outer `Row` places the timestamp at the far left and all
  ///   right-side controls (Subtitle, Audio, Volume, Next, Fullscreen)
  ///   at the far right. Middle of the Row is empty / a Spacer.
  /// - When "Erweiterte Werkzeuge" is on, the Screenshot+Clip pair is
  ///   rendered as a SECOND stack layer, absolutely centered via
  ///   `Align(center)`. This guarantees the vertical line through the
  ///   gap between those two buttons always passes through the
  ///   horizontal centerline of the player — which is also where the
  ///   big Play button sits, so the two rows line up visually.
  /// - The approach trades a tiny amount of layout complexity (Stack
  ///   instead of a single Row) for a result that's rock-solid
  ///   regardless of timestamp width or how many right-side controls
  ///   are visible. Previous `Spacer`-only layout would only center
  ///   when the left and right ends were the same width, which is
  ///   almost never the case.
  Widget _buildBottomControlRow() {
    final advanced = ref.watch(settingsProvider).advancedToolsEnabled;

    // Right-side icon group — built once so both layout branches
    // render the same visual.
    final rightGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_subtitleTracks.isNotEmpty || widget.subtitlePath != null) ...[
          _buildSubtitleDropdown(),
          const SizedBox(width: 6),
        ],
        if (_audioTracks.length > 1) ...[
          _buildAudioDropdown(),
          const SizedBox(width: 6),
        ],
        _buildVolumeControl(),
        const SizedBox(width: 6),
        if (widget.nextEpisodeFilePath != null) ...[
          _buildNextEpisodeButton(),
          const SizedBox(width: 6),
        ],
        IconButton(
          icon: Icon(
            _isFullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            color: AppTheme.textSecondary,
            size: 28,
          ),
          onPressed: _toggleFullscreen,
          tooltip: _isFullscreen ? 'Vollbild beenden' : 'Vollbild',
        ),
      ],
    );

    final timeText = Text(
      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
      style: const TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 13,
        fontFeatures: [FontFeature.tabularFigures()],
        shadows: [
          Shadow(
            blurRadius: 6,
            color: Color(0xCC000000),
            offset: Offset(0, 1),
          ),
        ],
      ),
    );

    // Base row: left edge = time, right edge = icon group, middle
    // empty (Spacer). In the non-advanced branch this is the whole row.
    final baseRow = Row(
      children: [
        timeText,
        const Spacer(),
        rightGroup,
      ],
    );

    if (!advanced) return baseRow;

    // Advanced mode: overlay a center-aligned Screenshot+Clip pair
    // on top of the base row. `IgnorePointer: false` (default) so the
    // buttons remain interactive; the Stack itself isn't given any
    // size — it inherits from whatever the parent Column gives it.
    return Stack(
      alignment: Alignment.center,
      children: [
        baseRow,
        // Pair is intentionally NOT wrapped in Expanded/Flexible —
        // a min-width Row lets the two IconButtons sit tightly next
        // to each other with the 6 px gap, and Align centers that
        // combined unit horizontally.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildScreenshotButton(),
            const SizedBox(width: 6),
            _buildClipButton(),
          ],
        ),
      ],
    );
  }

  Widget _buildSeekBar() {
    final thumbnailsEnabled = ref.watch(settingsProvider).thumbnailsEnabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        _seekbarWidth = constraints.maxWidth;
        final slider = SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 7,
            ),
            overlayShape: const RoundSliderOverlayShape(
              overlayRadius: 14,
            ),
            activeTrackColor: AppTheme.accent,
            inactiveTrackColor: AppTheme.progressBackground,
            thumbColor: AppTheme.accent,
          ),
          child: Slider(
            value: _seekDragging
                ? _seekValue
                : _duration.inMilliseconds > 0
                    ? _position.inMilliseconds
                        .toDouble()
                        .clamp(0, _duration.inMilliseconds.toDouble())
                    : 0,
            min: 0,
            max: _duration.inMilliseconds > 0
                ? _duration.inMilliseconds.toDouble()
                : 1,
            onChangeStart: (v) {
              _seekDragging = true;
              _seekValue = v;
            },
            onChanged: (v) {
              setState(() => _seekValue = v);
            },
            onChangeEnd: (v) {
              _seekDragging = false;
              _player.seek(Duration(milliseconds: v.toInt()));
              _startHideTimer();
            },
          ),
        );

        // When thumbnails are disabled we still track hover so the user gets
        // a timestamp tooltip at the hover point — only the image preview is
        // skipped (handled below by the _hoverThumbnailPath == null branch).
        return Stack(
          clipBehavior: Clip.none,
          children: [
            if (_hoverX != null && _hoverThumbnailPath != null)
              Positioned(
                bottom: 40,
                left: (_hoverX! - 120).clamp(
                  0.0,
                  (_seekbarWidth - 240).clamp(0.0, double.infinity),
                ),
                child: _buildHoverPreview(),
              ),
            if (_hoverX != null &&
                _hoverThumbnailPath == null &&
                _hoverTime != null)
              Positioned(
                bottom: 40,
                left: (_hoverX! - 40).clamp(
                  0.0,
                  (_seekbarWidth - 80).clamp(0.0, double.infinity),
                ),
                child: _buildHoverTimeLabel(),
              ),
            MouseRegion(
              onHover: (event) =>
                  _updateHover(event.localPosition.dx, thumbnailsEnabled),
              onExit: (_) {
                if (mounted) {
                  setState(() {
                    _hoverX = null;
                    _hoverTime = null;
                    _hoverThumbnailPath = null;
                    _hoverThumbnailIndex = null;
                  });
                }
              },
              child: slider,
            ),
            // Clip-start / clip-end markers — thin accent-colored dots
            // above the track showing the user where their pending clip
            // range begins and ends. Once both are set (second click)
            // both stay visible through dialog + export so the user has
            // a visual reference of what was included. Purely decorative
            // — IgnorePointer so they don't swallow drags on the seekbar.
            if (_clipStart != null &&
                _duration.inMilliseconds > 0 &&
                _seekbarWidth > 0)
              Positioned(
                left: _timeToSeekbarX(_clipStart!) - 6,
                top: 6,
                child: const IgnorePointer(child: _ClipMarkerDot()),
              ),
            if (_clipEnd != null &&
                _duration.inMilliseconds > 0 &&
                _seekbarWidth > 0)
              Positioned(
                left: _timeToSeekbarX(_clipEnd!) - 6,
                top: 6,
                child: const IgnorePointer(child: _ClipMarkerDot()),
              ),
          ],
        );
      },
    );
  }

  Widget _buildHoverPreview() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 240,
          height: 135,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
            image: DecorationImage(
              image: FileImage(File(_hoverThumbnailPath!)),
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            _hoverTime != null ? _formatDuration(_hoverTime!) : '',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHoverTimeLabel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Text(
        _hoverTime != null ? _formatDuration(_hoverTime!) : '',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _updateHover(double x, bool thumbnailsEnabled) {
    if (_duration.inMilliseconds <= 0 || _seekbarWidth <= 0) return;
    // Slider has horizontal padding (~12px). Compensate approximately.
    const sliderPadding = 12.0;
    final trackWidth = _seekbarWidth - 2 * sliderPadding;
    final relativeX = (x - sliderPadding).clamp(0.0, trackWidth);
    final fraction = trackWidth > 0 ? relativeX / trackWidth : 0.0;
    final hoverMs = (fraction * _duration.inMilliseconds).round();
    final hoverTime = Duration(milliseconds: hoverMs);

    // Only look up a thumbnail when the feature is actually enabled — saves
    // a disk hit on every mouse move when the user has turned previews off.
    if (thumbnailsEnabled) {
      // Compute thumbnail index (cheap, avoid state rebuild if unchanged)
      final thumbIndex =
          hoverTime.inSeconds ~/ ThumbnailService.intervalSeconds;

      if (thumbIndex != _hoverThumbnailIndex) {
        _hoverThumbnailIndex = thumbIndex;
        _hoverThumbnailPath = null;
        // Lookup asynchronously
        ThumbnailService.instance
            .getThumbnailAt(widget.filePath, hoverTime)
            .then((path) {
          if (!mounted) return;
          if (_hoverThumbnailIndex == thumbIndex) {
            setState(() => _hoverThumbnailPath = path);
          }
        });
      }
    } else if (_hoverThumbnailPath != null || _hoverThumbnailIndex != null) {
      // Feature toggled off mid-session — drop any leftover preview state.
      _hoverThumbnailPath = null;
      _hoverThumbnailIndex = null;
    }

    setState(() {
      _hoverX = x;
      _hoverTime = hoverTime;
    });
  }

  Widget _buildNextEpisodeButton() {
    return Tooltip(
      richMessage: widget.nextEpisodeTitle != null
          ? TextSpan(
              children: [
                const TextSpan(
                  text: 'Nächste Folge\n',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                  ),
                ),
                TextSpan(
                  text: widget.nextEpisodeTitle!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            )
          : const TextSpan(text: 'Nächste Folge'),
      decoration: BoxDecoration(
        color: const Color(0xF0282828),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      waitDuration: const Duration(milliseconds: 300),
      child: IconButton(
        icon: const Icon(
          Icons.skip_next_rounded,
          color: AppTheme.textSecondary,
          size: 26,
        ),
        onPressed: () {
          _isCompleted = true;
          _playNextEpisode();
        },
      ),
    );
  }

  Widget _buildCountdownButton({
    required VoidCallback onPressed,
    required String label,
    required IconData icon,
  }) {
    final progress = _countdownProgress;

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        children: [
          // Background: grey sweeps from left to right as countdown progresses
          Positioned.fill(
            child: Row(
              children: [
                // Grey portion (grows from left)
                if (progress > 0)
                  Expanded(
                    flex: (progress * 1000).round().clamp(0, 1000),
                    child: Container(color: const Color(0xFFBDBDBD)),
                  ),
                // Remaining white portion (shrinks)
                Expanded(
                  flex: ((1.0 - progress) * 1000).round().clamp(0, 1000),
                  child: Container(color: Colors.white),
                ),
              ],
            ),
          ),
          // Button content
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 20, color: Colors.black),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: const TextStyle(
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
        ],
      ),
    );
  }

  /// Full-screen overlay shown when playback cannot continue (file missing,
  /// unsupported codec, mpv error). Matches the style of the home-screen
  /// error state so the user gets consistent, readable feedback.
  Widget _buildErrorOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.92),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded,
                    size: 72, color: AppTheme.accent),
                const SizedBox(height: 20),
                Text(
                  'Wiedergabe nicht möglich',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(
                    _playbackError ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                ElevatedButton.icon(
                  onPressed: _stopAndGoBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                  label: const Text('Zurück'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNextEpisodeOverlay() {
    return Positioned(
      bottom: 100,
      right: 24,
      child: AnimatedOpacity(
        opacity: _showNextEpisode ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(16),
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
                    _watchingCredits ? 'Nächste Folge nach dem Abspann' : 'Nächste Folge',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              if (widget.nextEpisodeTitle != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.nextEpisodeTitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              if (!_watchingCredits)
                Row(
                  children: [
                    Expanded(
                      child: _buildCountdownButton(
                        onPressed: () {
                          _isCompleted = true;
                          _playNextEpisode();
                        },
                        label: 'Nächste Folge',
                        icon: Icons.play_arrow_rounded,
                      ),
                    ),
                  ],
                ),
              if (!_watchingCredits) const SizedBox(height: 8),
              if (!_watchingCredits)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          setState(() => _watchingCredits = true);
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.textSecondary,
                          side: const BorderSide(
                              color: AppTheme.textMuted, width: 1),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        child: const Text('Abspann ansehen'),
                      ),
                    ),
                  ],
                ),
              if (_watchingCredits)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          _isCompleted = true;
                          _playNextEpisode();
                        },
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Jetzt abspielen'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    // We DO handle KeyRepeatEvent in addition to KeyDownEvent so holding
    // an arrow key keeps seeking / adjusting volume instead of firing
    // exactly once. KeyUpEvent is still ignored — "up" should never
    // trigger the action. Keys that should NOT auto-repeat (Space,
    // shortcuts like C/M/F/1/2/P) are filtered per-case below.
    if (event is KeyUpEvent) return;
    final isRepeat = event is KeyRepeatEvent;

    _showControls();

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        // Holding space must NOT toggle play/pause rapidly — that would
        // flicker the player. Only the initial down-press acts.
        if (isRepeat) break;
        _isPlaying ? _player.pause() : _player.play();
        break;
      case LogicalKeyboardKey.arrowLeft:
        final newPos = _position - const Duration(seconds: 10);
        _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
        break;
      case LogicalKeyboardKey.arrowRight:
        final newPos = _position + const Duration(seconds: 10);
        _player.seek(newPos > _duration ? _duration : newPos);
        break;
      case LogicalKeyboardKey.arrowUp:
        // One step louder (5%). Also implicitly un-mutes — see _stepVolume.
        _stepVolume(5);
        break;
      case LogicalKeyboardKey.arrowDown:
        _stepVolume(-5);
        break;
      case LogicalKeyboardKey.escape:
        _stopAndGoBack();
        break;
      // "C" is the new primary subtitle toggle. "S" kept as an alias so
      // users who learned the old shortcut don't lose muscle memory
      // (costs nothing — no conflict, both map to the same action).
      case LogicalKeyboardKey.keyC:
      case LogicalKeyboardKey.keyS:
        if (isRepeat) break;
        _toggleSubtitles();
        break;
      case LogicalKeyboardKey.keyA:
        if (isRepeat) break;
        _cycleAudioTrack();
        break;
      case LogicalKeyboardKey.keyF:
        if (isRepeat) break;
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.keyM:
        if (isRepeat) break;
        _flashVolumeOverlay();
        _toggleMute();
        break;
      // Advanced-tools shortcuts (P / 1 / 2) are only honoured when the
      // "Erweiterte Werkzeuge" toggle is on. Otherwise the feature is
      // effectively off everywhere: no button in the UI, and no hidden
      // keyboard path either. `isRepeat` also guards against auto-
      // repeat triggering accidental double-captures while held.
      case LogicalKeyboardKey.keyP:
        if (isRepeat) break;
        if (!_advancedEnabled) break;
        // Photo / screenshot. Guarded by the same _isExporting flag as
        // the click path so a user mashing P can't queue parallel
        // ffmpeg runs on the same output filename.
        if (!_isExporting) _onScreenshotPressed();
        break;
      case LogicalKeyboardKey.digit1:
        if (isRepeat) break;
        if (!_advancedEnabled) break;
        // Clip-start. Only fires when we're NOT already mid-clip —
        // pressing "1" twice in a row should feel like "re-mark start",
        // but if an end is pending (clip armed) we ignore it to avoid
        // wiping work.
        if (!_isExporting && _clipStart == null) {
          _onClipPressed();
        }
        break;
      case LogicalKeyboardKey.digit2:
        if (isRepeat) break;
        if (!_advancedEnabled) break;
        // Clip-end. Only valid while a start is pending; otherwise "2"
        // does nothing, rather than silently creating a start point at
        // a random moment and confusing the user.
        if (!_isExporting && _clipStart != null && _clipEnd == null) {
          _onClipPressed();
        }
        break;
      default:
        break;
    }
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------------
  // Export (screenshot / clip) helpers
  // ---------------------------------------------------------------------

  /// Converts a playback timestamp to an X coordinate on the seekbar, so we
  /// can draw the pending clip-start marker aligned with the current
  /// position fraction. Matches the 12-px slider padding used in
  /// [_updateHover] so the marker sits exactly where the thumb would be.
  double _timeToSeekbarX(Duration time) {
    if (_duration.inMilliseconds <= 0 || _seekbarWidth <= 0) return 0;
    const sliderPadding = 12.0;
    final trackWidth = _seekbarWidth - 2 * sliderPadding;
    final fraction =
        (time.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    return sliderPadding + fraction * trackWidth;
  }

  Widget _buildScreenshotButton() {
    return IconButton(
      icon: Icon(
        Icons.photo_camera_rounded,
        color: _isExporting ? AppTheme.textMuted : AppTheme.textSecondary,
        size: 24,
      ),
      tooltip: 'Foto von aktueller Szene',
      onPressed: _isExporting ? null : _onScreenshotPressed,
    );
  }

  /// Non-blocking banner shown while a clip is armed (start marked, end
  /// pending). Sits above the seek bar — unlike the old SnackBar, it does
  /// NOT overlap the clip button, so the user can freely tap again to
  /// finalize the clip. Includes an explicit "Abbrechen" button for the
  /// "whoops wrong spot" case.
  Widget _buildClipInfoPill() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.accent, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulsingDot(),
              const SizedBox(width: 8),
              Text(
                'Clip-Anfang bei ${_formatDuration(_clipStart!)} · '
                'erneut auf Video-Icon klicken für Endpunkt',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  if (mounted) {
                    setState(() {
                      _clipStart = null;
                      _clipEnd = null;
                    });
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    color: AppTheme.textSecondary,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClipButton() {
    final inClipMode = _clipStart != null;
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          icon: Icon(
            inClipMode
                ? Icons.stop_circle_rounded
                : Icons.videocam_rounded,
            color: _isExporting
                ? AppTheme.textMuted
                : (inClipMode ? AppTheme.accent : AppTheme.textSecondary),
            size: 24,
          ),
          tooltip: inClipMode
              ? 'Clip-Ende setzen & speichern'
              : 'Clip-Anfang markieren',
          onPressed: _isExporting ? null : _onClipPressed,
        ),
        // Subtle "recording" dot pulsing on the icon while a clip is in
        // progress so the user doesn't forget they're mid-marking.
        if (inClipMode)
          const Positioned(
            right: 6,
            top: 6,
            child: _PulsingDot(),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // New consolidated controls: subtitles dropdown, audio dropdown, volume
  // ---------------------------------------------------------------------

  /// Subtitle track dropdown — uses the custom `_IconMenuButton` (see
  /// bottom of this file) which opens INSTANTLY via OverlayPortal,
  /// unlike Flutter's PopupMenuButton which has a hardcoded 300 ms
  /// transition. Also gives us a proper IconButton-style hover splash
  /// (matches Fullscreen / Next Episode) and a real tooltip string
  /// instead of the "Show menu" default.
  Widget _buildSubtitleDropdown() {
    // "Off" means: the user toggled subs off, OR mpv reports the
    // explicit no-subtitle sentinel, OR no track event has ever
    // arrived. In all three cases we want the "Aus" entry checked.
    final activeId = _activeSubtitleTrack?.id;
    final isOff = !_subtitlesEnabled ||
        activeId == null ||
        activeId == SubtitleTrack.no().id;

    // mpv fires the track event with id='auto' for the first pick
    // (e.g. the default-flagged sub in an .mkv). That sentinel never
    // equals any real track id, so comparing directly leaves every
    // entry unchecked. Map 'auto' back to the first real track —
    // which is exactly what mpv's default selection resolves to.
    final activeIsReal = !isOff;
    final effectiveActiveId = !activeIsReal
        ? null
        : (activeId == 'auto'
            ? (_subtitleTracks.isNotEmpty ? _subtitleTracks.first.id : null)
            : activeId);

    final entries = <_MenuEntry>[
      // "Aus" at the top — standard media-player convention, and
      // guarantees it's reachable even with a long track list.
      _MenuEntry(
        label: 'Aus',
        selected: isOff,
        onTap: () async {
          await _player.setSubtitleTrack(SubtitleTrack.no());
          if (!mounted) return;
          setState(() => _subtitlesEnabled = false);
        },
      ),
      for (final track in _subtitleTracks)
        _MenuEntry(
          label: track.title ?? track.language ?? 'Spur ${track.id}',
          selected:
              effectiveActiveId != null && effectiveActiveId == track.id,
          onTap: () async {
            await _player.setSubtitleTrack(track);
            if (!mounted) return;
            setState(() {
              _subtitlesEnabled = true;
              _lastChosenSubtitleTrack = track;
            });
          },
        ),
    ];

    return _IconMenuButton(
      icon: activeIsReal
          ? Icons.subtitles_rounded
          : Icons.subtitles_off_rounded,
      iconColor:
          activeIsReal ? AppTheme.textSecondary : AppTheme.textMuted,
      tooltip: 'Untertitel',
      entries: entries,
    );
  }

  /// Audio track dropdown. Filled speech-bubble icon reads as "voice /
  /// language". No "Aus" entry because muting is the volume button's
  /// job.
  Widget _buildAudioDropdown() {
    // Same 'auto' sentinel issue as subtitles: mpv's initial track
    // event reports id='auto' for its default audio pick, which
    // never matches any real track id. Fall back to the first track
    // — mpv's default selection resolves to exactly that.
    final activeId = _activeAudioTrack?.id;
    final effectiveActiveId = (activeId == null || activeId == 'auto')
        ? (_audioTracks.isNotEmpty ? _audioTracks.first.id : null)
        : activeId;

    final entries = _audioTracks
        .map((track) => _MenuEntry(
              label: track.title ??
                  track.language ??
                  'Spur ${track.id}',
              selected:
                  effectiveActiveId != null && effectiveActiveId == track.id,
              onTap: () {
                _player.setAudioTrack(track);
                _startHideTimer();
              },
            ))
        .toList();

    return _IconMenuButton(
      icon: Icons.chat_rounded,
      iconColor: AppTheme.textSecondary,
      tooltip: 'Audiospuren',
      entries: entries,
    );
  }

  /// Volume control: speaker icon + vertical slider popup.
  ///
  /// Architecture:
  /// - `OverlayPortal` renders the popup into the app Overlay rather
  ///   than as an in-Stack `Positioned`. This matters because an
  ///   in-Stack Positioned that paints OUTSIDE the Stack's bounds only
  ///   receives paint — not hit tests. That was the "hover snaps away
  ///   the moment I reach the slider" bug.
  /// - `CompositedTransformTarget` + `CompositedTransformFollower`
  ///   keep the popup pinned to the icon's position even as the bottom
  ///   bar reflows.
  /// - Hover state is delayed-hide via `_scheduleVolumeHide` (400 ms)
  ///   so travelling between icon and slider doesn't flicker the popup.
  /// - The popup's own MouseRegion keeps the hover state alive while
  ///   the cursor is anywhere inside the popup — its black background
  ///   AND the red slider count equally.
  /// - No `tooltip:` on the IconButton: the popup IS the feedback, and
  ///   a second "Stummschalten" text tooltip would cover the slider
  ///   itself, which is exactly what the user was trying to reach.
  Widget _buildVolumeControl() {
    return CompositedTransformTarget(
      link: _volumeLink,
      child: OverlayPortal(
        controller: _volumeOverlayCtrl,
        // The overlay is a Stack — a non-Positioned child would be
        // stretched to the Stack's full size (screen-sized), which is
        // how the earlier version ended up covering half the screen
        // with a tinted Material. Positioned(left:0, top:0) anchors it
        // so CompositedTransformFollower is the one that decides its
        // actual paint position.
        overlayChildBuilder: (ctx) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _volumeLink,
            // Anchor popup's BOTTOM CENTER to the icon's TOP CENTER so
            // the popup opens directly above. Slight -6 px gap for
            // breathing room between the two.
            followerAnchor: Alignment.bottomCenter,
            targetAnchor: Alignment.topCenter,
            offset: const Offset(0, -6),
            showWhenUnlinked: false,
            child: MouseRegion(
              onEnter: (_) => _cancelVolumeHide(),
              onExit: (_) => _scheduleVolumeHide(),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                      color: AppTheme.textMuted.withValues(alpha: 0.4)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Numeric readout on top. tabularFigures so the
                    // digits don't shift horizontally as they change.
                    SizedBox(
                      width: 34,
                      child: Text(
                        '${(_isMuted ? 0.0 : _volume).round()}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Vertical slider. Flutter doesn't ship a native
                    // vertical Slider, so we rotate a standard one by
                    // 270° (quarterTurns: 3). 140 px tall gives enough
                    // resolution to hit 5%-ish steps comfortably.
                    SizedBox(
                      height: 140,
                      width: 32,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 7),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12),
                            activeTrackColor: AppTheme.accent,
                            inactiveTrackColor: AppTheme.textMuted
                                .withValues(alpha: 0.4),
                            thumbColor: AppTheme.accent,
                            overlayColor:
                                AppTheme.accent.withValues(alpha: 0.2),
                          ),
                          child: Slider(
                            value: (_isMuted ? 0.0 : _volume)
                                .clamp(0.0, 100.0),
                            min: 0,
                            max: 100,
                            onChanged: (v) => _setVolume(v),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Icon(_volumeIcon,
                        color: AppTheme.textSecondary, size: 18),
                  ],
                ),
                ),
              ),
            ),
          ),
        ),
        child: MouseRegion(
          onEnter: (_) => _cancelVolumeHide(),
          onExit: (_) => _scheduleVolumeHide(),
          child: IconButton(
            icon: Icon(
              _volumeIcon,
              color: _isMuted ? AppTheme.accent : AppTheme.textSecondary,
              size: 24,
            ),
            onPressed: _toggleMute,
          ),
        ),
      ),
    );
  }

  Future<void> _onScreenshotPressed() async {
    final exportFolder = ref.read(settingsProvider).exportFolderPath;
    if (exportFolder == null) {
      _promptConfigureExportFolder();
      return;
    }

    // Capture the frame FIRST (before any dialogs that could cause the
    // player to blur / loose focus). PNG for lossless stills.
    Uint8List? bytes;
    try {
      bytes = await _player.screenshot(format: 'image/png');
    } catch (e) {
      _showExportError('Foto konnte nicht aufgenommen werden: $e');
      return;
    }
    if (bytes == null) {
      _showExportError(
          'Foto konnte nicht aufgenommen werden — Video-Frame nicht verfügbar.');
      return;
    }

    if (!mounted) return;
    final name = await _askFilename(
      title: 'Foto speichern',
      suggestion: _suggestName(suffix: 'foto'),
    );
    if (name == null) return; // user cancelled

    setState(() => _isExporting = true);
    final result = await ExportService.instance.saveScreenshot(
      pngBytes: bytes,
      exportFolder: exportFolder,
      name: name,
    );
    if (!mounted) return;
    setState(() => _isExporting = false);
    _showExportResult(result, kind: 'Foto');
  }

  Future<void> _onClipPressed() async {
    final exportFolder = ref.read(settingsProvider).exportFolderPath;
    if (exportFolder == null) {
      _promptConfigureExportFolder();
      return;
    }

    // First click — arm the clip. NO SnackBar here: the user needs the
    // clip button clickable for the second marker, and a SnackBar sitting
    // over the bottom bar blocks the tap target. The state is communicated
    // via the inline pill rendered above the seek bar + the clip icon
    // turning red with a pulsing dot.
    if (_clipStart == null) {
      setState(() => _clipStart = _position);
      return;
    }

    // Second click — freeze the end marker at the current position. We set
    // it BEFORE awaiting the dialog so both markers are painted on the
    // seekbar immediately, giving the user a visual anchor of the selected
    // range while they type the filename / ffmpeg crunches.
    setState(() => _clipEnd = _position);

    final start = _clipStart!;
    final end = _clipEnd!;
    // Allow reverse marking (user seeked backwards) by swapping.
    final lo = start <= end ? start : end;
    final hi = start <= end ? end : start;

    if ((hi - lo).inMilliseconds < 500) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Clip zu kurz (< 0,5 s) — bitte etwas weiter spulen und erneut markieren.'),
          duration: Duration(seconds: 4),
        ),
      );
      setState(() {
        _clipStart = null;
        _clipEnd = null;
      });
      return;
    }

    final name = await _askFilename(
      title: 'Clip speichern (${_formatDuration(hi - lo)})',
      suggestion: _suggestName(suffix: 'clip'),
    );
    if (!mounted) return;
    if (name == null) {
      // User cancelled — wipe both markers, the selection is gone.
      setState(() {
        _clipStart = null;
        _clipEnd = null;
      });
      return;
    }

    setState(() {
      _isExporting = true;
    });
    // Inform the user — ffmpeg re-encoding can take several seconds.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                color: AppTheme.accent,
                strokeWidth: 2,
              ),
            ),
            SizedBox(width: 14),
            Expanded(child: Text('Clip wird exportiert …')),
          ],
        ),
        duration: Duration(minutes: 30),
      ),
    );

    final result = await ExportService.instance.exportClip(
      sourceVideoPath: widget.filePath,
      start: lo,
      end: hi,
      exportFolder: exportFolder,
      name: name,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    setState(() {
      _isExporting = false;
      _clipStart = null;
      _clipEnd = null;
    });
    _showExportResult(result, kind: 'Clip');
  }

  /// Human-friendly default filename: "<Title> <Episode?> - <suffix> <mm.ss>".
  /// Timestamped so hitting the screenshot button twice rapidly gives two
  /// different default names (the ExportService also handles collisions, but
  /// this makes the names readable).
  String _suggestName({required String suffix}) {
    final parts = <String>[widget.title];
    if (widget.episodeTitle != null && widget.episodeTitle!.isNotEmpty) {
      parts.add(widget.episodeTitle!);
    }
    final ts = _formatDuration(_position).replaceAll(':', '.');
    return '${parts.join(' - ')} - $suffix $ts';
  }

  /// Modal filename prompt. Returns the user's input, or null on cancel.
  /// Pauses playback while open so the user's timestamp choice doesn't
  /// drift while they type.
  Future<String?> _askFilename({
    required String title,
    required String suggestion,
  }) async {
    final wasPlaying = _isPlaying;
    if (wasPlaying) _player.pause();

    final controller = TextEditingController(text: suggestion);
    // Select the whole default so the user can just start typing to replace.
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: suggestion.length,
    );

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          // No label / hint — keeps the field visually clean (user complaint:
          // placeholder text fading in/out while typing felt noisy). The
          // field is pre-filled with a sensible default instead.
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Speichern',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );

    // Resume only if the user actually confirmed — if they cancelled, keep
    // the video paused so they can try again without re-finding the frame.
    if (wasPlaying && result != null) _player.play();
    final trimmed = result?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  void _promptConfigureExportFolder() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
            'Kein Export-Ordner gesetzt. Bitte in den Einstellungen wählen.'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Einstellungen',
          textColor: AppTheme.accent,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ),
    );
  }

  void _showExportResult(ExportResult result, {required String kind}) {
    if (result.isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$kind gespeichert:\n${result.path}'),
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      _showExportError(result.error ?? 'Unbekannter Fehler');
    }
  }

  void _showExportError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppTheme.accent, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(msg)),
          ],
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }
}

/// Stateless marker dot used on the seekbar to annotate clip start/end.
/// Identical shape/size for both ends so the user reads them as a pair.
class _ClipMarkerDot extends StatelessWidget {
  const _ClipMarkerDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: AppTheme.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 4,
          ),
        ],
      ),
    );
  }
}

/// Small blinking red dot indicating an active clip-marking session.
/// Encapsulated so we can animate without touching the main player state.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(_ctrl),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: AppTheme.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// A single selectable row inside an [_IconMenuButton] dropdown.
///
/// Kept as a tiny plain data class rather than reusing `PopupMenuItem`
/// so we don't drag Flutter's popup-route machinery back in via the
/// type system — the whole point of the custom menu is to sidestep
/// that 300 ms animated route.
class _MenuEntry {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _MenuEntry({
    required this.label,
    required this.selected,
    required this.onTap,
  });
}

/// Fast, instant-opening dropdown attached to an IconButton. Used for
/// the subtitle + audio track pickers in the player's bottom bar.
///
/// Why not [PopupMenuButton]?
///  - PopupMenuButton has a hardcoded 300 ms open transition (see
///    `_PopupMenuRoute.transitionDuration` in the Flutter SDK). With
///    everything else in the UI feeling immediate, that half-second
///    read as "the app is lagging".
///  - Its `child:` slot doesn't get IconButton-style hover splash,
///    which visually broke symmetry with the adjacent Fullscreen and
///    Next Episode buttons.
///  - Its default "Show menu" tooltip couldn't be suppressed just by
///    wrapping the button in an outer Tooltip.
///
/// This widget renders the menu via [OverlayPortal] +
/// [CompositedTransformFollower] so it appears instantly, pinned
/// above the trigger. A full-screen transparent
/// [GestureDetector] under the menu handles tap-outside-to-close
/// without swallowing pointer events when the menu isn't open.
class _IconMenuButton extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String tooltip;
  final List<_MenuEntry> entries;
  final double iconSize;

  const _IconMenuButton({
    required this.icon,
    required this.iconColor,
    required this.tooltip,
    required this.entries,
    this.iconSize = 24,
  });

  @override
  State<_IconMenuButton> createState() => _IconMenuButtonState();
}

class _IconMenuButtonState extends State<_IconMenuButton> {
  final OverlayPortalController _ctrl = OverlayPortalController();
  final LayerLink _link = LayerLink();

  // Hover-tracked auto-close. We keep two flags (trigger + popup) so
  // travelling the cursor between the button and the menu items
  // doesn't dismiss the menu in the gap between them. Closes 600 ms
  // after the pointer has been outside BOTH.
  bool _triggerHovered = false;
  bool _popupHovered = false;
  Timer? _autoCloseTimer;

  /// Tracks the menu that is currently open across the whole app so
  /// clicking a sibling dropdown button can close the previous one
  /// instantly — without this, both menus would briefly coexist on
  /// screen which feels glitchy (and wastes a tap-outside cycle).
  static _IconMenuButtonState? _activeMenu;

  void _openMenu() {
    // Close any other menu that was already open — the new one
    // "steals" focus, matching native menubar behaviour.
    if (_activeMenu != null && _activeMenu != this) {
      _activeMenu!._closeMenu();
    }
    if (!_ctrl.isShowing) _ctrl.show();
    _activeMenu = this;
  }

  void _closeMenu() {
    _autoCloseTimer?.cancel();
    if (_ctrl.isShowing) _ctrl.hide();
    if (_activeMenu == this) _activeMenu = null;
  }

  void _toggle() {
    if (_ctrl.isShowing) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _scheduleAutoClose() {
    _autoCloseTimer?.cancel();
    if (!_ctrl.isShowing) return;
    _autoCloseTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      if (!_triggerHovered && !_popupHovered) _closeMenu();
    });
  }

  void _cancelAutoClose() {
    _autoCloseTimer?.cancel();
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    // Clear the static handle so a rebuilt widget doesn't see a
    // dangling pointer to a disposed state.
    if (_activeMenu == this) _activeMenu = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _ctrl,
        // Overlay is a Stack — non-Positioned children get stretched
        // to full overlay size. Wrap in Positioned(0,0) so
        // CompositedTransformFollower owns the actual position.
        overlayChildBuilder: (overlayCtx) => Positioned(
          left: 0,
          top: 0,
          child: CompositedTransformFollower(
            link: _link,
            // Anchor the popup's BOTTOM-RIGHT to the button's
            // TOP-RIGHT — menu extends leftward from the button's
            // right edge, which keeps it on-screen for controls
            // living near the right side of the bottom bar.
            followerAnchor: Alignment.bottomRight,
            targetAnchor: Alignment.topRight,
            offset: const Offset(0, -6),
            showWhenUnlinked: false,
            child: MouseRegion(
              onEnter: (_) {
                _popupHovered = true;
                _cancelAutoClose();
              },
              onExit: (_) {
                _popupHovered = false;
                _scheduleAutoClose();
              },
              child: Material(
                color: AppTheme.surface,
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                // Cap the menu height so long track lists (e.g. MKVs
                // with many audio dubs or subtitles) stay on-screen
                // and become scrollable rather than being clipped by
                // the overlay edge.
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        MediaQuery.of(overlayCtx).size.height * 0.6,
                  ),
                  child: IntrinsicWidth(
                  child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.entries.map((entry) {
                      return InkWell(
                        onTap: () {
                          _closeMenu();
                          entry.onTap();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Reserve a fixed-width gutter so
                              // selected and unselected rows keep
                              // their label at the same X, instead
                              // of the check glyph shifting text.
                              SizedBox(
                                width: 24,
                                child: entry.selected
                                    ? const Icon(
                                        Icons.check_rounded,
                                        color: AppTheme.accent,
                                        size: 18,
                                      )
                                    : null,
                              ),
                              Text(
                                entry.label,
                                style: TextStyle(
                                  color: entry.selected
                                      ? AppTheme.accent
                                      : AppTheme.textPrimary,
                                  fontWeight: entry.selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  ),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: MouseRegion(
          onEnter: (_) {
            _triggerHovered = true;
            _cancelAutoClose();
          },
          onExit: (_) {
            _triggerHovered = false;
            _scheduleAutoClose();
          },
          child: IconButton(
            icon: Icon(widget.icon,
                color: widget.iconColor, size: widget.iconSize),
            tooltip: widget.tooltip,
            onPressed: _toggle,
          ),
        ),
      ),
    );
  }
}
