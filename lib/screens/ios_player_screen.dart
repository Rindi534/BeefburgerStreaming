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
import 'player_screen.dart';

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
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  String? _playbackError;
  bool _completionHandled = false;
  bool _navigatingToNext = false;

  @override
  void dispose() {
    _saveProgress();
    _progressTimer?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    // Controller itself is disposed by the IOSNativePlayerView's
    // State when the widget unmounts — we don't own that lifecycle.
    super.dispose();
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

  void _saveProgress() {
    final ctrl = _controller;
    if (ctrl == null || widget.mediaId == null) return;
    final pos = ctrl.position;
    final dur = ctrl.duration;
    if (dur.inSeconds <= 0) return;
    ref.read(watchProgressProvider.notifier).updateProgress(
          mediaId: widget.mediaId!,
          filePath: widget.filePath,
          position: pos,
          totalDuration: dur,
          mediaTitle: widget.title,
          episodeTitle: widget.episodeTitle,
        );
  }

  void _onPlaybackComplete() {
    _saveProgress();
    // Auto-next: if we have a next episode, open it. No countdown
    // overlay on iOS for now — AVPlayerViewController renders the
    // end-of-file black frame which is the natural cue.
    if (widget.nextEpisodeFilePath != null && !_navigatingToNext) {
      _navigatingToNext = true;
      _playNextEpisode();
    }
  }

  void _playNextEpisode() {
    if (!mounted) return;
    final nextIdx = (widget.currentEpisodeIndex ?? -1) + 1;
    final all = widget.allEpisodes;
    final hasList = all != null && nextIdx < all.length;
    final nextEp = hasList ? all[nextIdx] : null;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          filePath: widget.nextEpisodeFilePath!,
          title: widget.title,
          episodeTitle: widget.nextEpisodeTitle,
          mediaId: nextEp != null
              ? '${widget.mediaId?.split('::').first ?? ''}::${nextEp.filePath}'
              : null,
          subtitlePath: widget.nextEpisodeSubtitlePath,
          nextEpisodeFilePath: hasList && nextIdx + 1 < all.length
              ? all[nextIdx + 1].filePath
              : null,
          nextEpisodeTitle: hasList && nextIdx + 1 < all.length
              ? all[nextIdx + 1].displayName
              : null,
          nextEpisodeSubtitlePath: hasList && nextIdx + 1 < all.length
              ? all[nextIdx + 1].subtitlePath
              : null,
          allEpisodes: all,
          currentEpisodeIndex: nextIdx,
        ),
      ),
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

          // Minimal back button in the top-left — AVPlayerViewController
          // has its own "Done" button but it only shows in fullscreen
          // mode. In inline mode (and during PiP transitions) users
          // need a reliable escape hatch.
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: SafeArea(
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
