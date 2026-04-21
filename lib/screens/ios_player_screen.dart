// iOS/iPadOS player screen.
//
// Deliberately *thin*: AVPlayerViewController already provides a full
// playback UI (play/pause, scrub with frame previews, subtitle picker,
// audio-track picker, PiP, AirPlay, fullscreen, speed). Duplicating
// any of that in Flutter would fight the native gestures.
//
// What we DO handle in Flutter here:
//   * Watch-progress save every 5 seconds + on close
//   * Resume-from-position on open
//   * Auto-play next episode at end (same logic as the desktop player)
//   * Fatal-error overlay if the file can't be opened
//
// Everything else — UI chrome, volume, seek, subtitles, PiP — is
// delegated to the native AVPlayerViewController.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/episode.dart';
import '../providers/watch_progress_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/ios_native_player_view.dart';

class IOSPlayerScreen extends ConsumerStatefulWidget {
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

  const IOSPlayerScreen({
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
  ConsumerState<IOSPlayerScreen> createState() => _IOSPlayerScreenState();
}

class _IOSPlayerScreenState extends ConsumerState<IOSPlayerScreen> {
  IOSNativePlayerController? _controller;
  Timer? _progressTimer;
  Timer? _closeButtonHideTimer;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  String? _playbackError;
  bool _completionHandled = false;
  // Navigation to another PlayerScreen is no longer needed on iOS —
  // we swap media in-place via IOSNativePlayerController.replaceMedia,
  // which keeps the AVPlayer (and any active PiP window) alive across
  // episodes. The old _navigatingToNext guard is gone with that path.
  // Close-button visibility. Starts visible so the user can always
  // get out in the first seconds, then fades away with the same
  // cadence as AVPlayerViewController's own chrome (~3s).
  bool _closeButtonVisible = true;

  // --- Mutable per-episode state ---
  // The widget's fields (filePath, mediaId, ...) describe the INITIAL
  // episode only. When auto-next fires we swap the AVPlayer's media
  // in-place (so PiP stays open), which means the logical "current
  // episode" diverges from widget.X. These fields track the live
  // episode for progress saves and the next-next lookup.
  late String _currentFilePath;
  late String? _currentEpisodeTitle;
  late String? _currentMediaId;
  // Mirrored for symmetry with the other _current* fields and to make
  // future read-sites (e.g. re-asserting the subtitle track after a
  // resume) trivial; currently only written.
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
    _scheduleCloseButtonHide();
  }

  @override
  void dispose() {
    _saveProgress();
    _progressTimer?.cancel();
    _closeButtonHideTimer?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    // Controller itself is disposed by the IOSNativePlayerView's
    // State when the widget unmounts — we don't own that lifecycle.
    super.dispose();
  }

  /// Fades the close-X out after ~3 seconds. Tapping anywhere on the
  /// player brings it back — see the transparent GestureDetector in
  /// build(). We don't try to sync with AVPlayer's own chrome because
  /// UIKit doesn't broadcast that state to Flutter; instead we use the
  /// same timing (3s, matching Apple's standard) so they visually
  /// align in practice.
  void _scheduleCloseButtonHide() {
    _closeButtonHideTimer?.cancel();
    _closeButtonHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _closeButtonVisible = false);
    });
  }

  void _revealCloseButton() {
    if (!_closeButtonVisible) {
      setState(() => _closeButtonVisible = true);
    }
    _scheduleCloseButtonHide();
  }

  void _onReady(IOSNativePlayerController ctrl) {
    _controller = ctrl;

    // Persist progress every 5 seconds — matches desktop cadence.
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
  }

  void _saveProgress({bool treatAsCompleted = false}) {
    final ctrl = _controller;
    // We read from the mutable _current* fields, NOT widget.X: after
    // an in-place episode swap, widget.filePath still points at the
    // FIRST episode we opened with, while the player is now actually
    // on episode N+1. Using widget.X here would silently write the
    // wrong episode's progress record.
    final mediaId = _currentMediaId;
    if (ctrl == null || mediaId == null) return;
    final dur = ctrl.duration;
    if (dur.inSeconds <= 0) return;
    // On completion we pin the saved position to the full duration.
    // AVPlayer's .AVPlayerItemDidPlayToEndTime can fire before the
    // periodic time-observer ticks one last time, so `ctrl.position`
    // may read e.g. 99.4% at that exact moment — below our 90% "seen"
    // threshold is fine, but we want the home screen to surface the
    // NEXT episode in Weiterschauen, which only happens when the
    // current one is marked as completed (progress >= 0.9). Pinning
    // to `dur` removes all ambiguity.
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
    // Pin progress to full duration so the episode is definitively
    // marked as seen — otherwise "Weiterschauen" on the home screen
    // won't advance to the next episode.
    _saveProgress(treatAsCompleted: true);
    _playNextEpisode();
  }

  /// Determine what the next episode is, based on the *current* (not
  /// initial) episode index. Works across season boundaries because
  /// `widget.allEpisodes` is the flat list across all seasons.
  Episode? _lookupNextEpisode() {
    final all = widget.allEpisodes;
    final idx = _currentEpisodeIndex;
    if (all == null || idx == null) return null;
    final next = idx + 1;
    if (next >= all.length) return null;
    return all[next];
  }

  /// Transition to the next episode *in-place*: keep the same AVPlayer
  /// (and therefore the same Picture-in-Picture window, if active), and
  /// just swap the media URL. Updates our mutable _current* state so
  /// subsequent progress saves land on the right episode record.
  ///
  /// On first-episode-only videos (movies, or the last episode of a
  /// series) this is a no-op and the user stays on the end-of-file
  /// frame until they close the player manually.
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
      // mediaId follows the "<seriesKey>::<episodeFilePath>" convention
      // used by the rest of the app, so the home screen can map a
      // progress record back to the right series when rendering
      // "Weiterschauen".
      _currentMediaId = widget.mediaId != null
          ? '${widget.mediaId!.split('::').first}::${nextEp.filePath}'
          : null;
      _completionHandled = false;
    });

    ctrl.replaceMedia(
      filePath: nextEp.filePath,
      subtitlePath: nextEp.subtitlePath,
      // Start from 0 — if the user had already partially watched the
      // next episode, that progress record exists but we intentionally
      // start fresh here (matches Netflix/desktop behavior where an
      // auto-next always begins at 0, even if you'd tapped away from
      // the episode earlier).
      startPosition: Duration.zero,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // We let AVPlayerViewController own the chrome; no AppBar, no
      // back button overlay. The user returns via swipe-down / the
      // built-in Done button inside the native UI.
      body: Stack(
        children: [
          // The native player fills the whole screen. Its own controls
          // (scrub bar, subtitle picker, PiP) layer on top via UIKit.
          Positioned.fill(
            child: IOSNativePlayerView(
              filePath: widget.filePath,
              subtitlePath: widget.subtitlePath,
              startPosition: widget.startPosition,
              onReady: _onReady,
            ),
          ),

          // Transparent reveal-tap zone in the top-left corner. Stays
          // narrow so it doesn't swallow interactions with the native
          // AVPlayer chrome (scrub bar, subtitle button). Tapping here
          // while the X is hidden brings it back for another 3 seconds.
          Positioned(
            top: 0,
            left: 0,
            width: 80,
            height: MediaQuery.of(context).padding.top + 60,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _revealCloseButton,
            ),
          ),

          // Minimal back button in the top-left — AVPlayerViewController
          // has its own "Done" button but it only shows in fullscreen
          // mode. In inline mode (and during PiP transitions) users
          // need a reliable escape hatch.
          //
          // Fades out after 3s so it doesn't permanently hover on top
          // of the video. IgnorePointer while invisible lets touches
          // pass through to the native AVPlayer chrome underneath;
          // the separate reveal-tap zone above brings it back.
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: SafeArea(
              child: AnimatedOpacity(
                opacity: _closeButtonVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !_closeButtonVisible,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(22),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      tooltip: 'Schließen',
                      onPressed: () {
                        _saveProgress();
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),

          if (_playbackError != null)
            Positioned.fill(child: _buildErrorOverlay()),
        ],
      ),
    );
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
