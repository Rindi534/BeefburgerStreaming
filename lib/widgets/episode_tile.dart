import 'package:flutter/material.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import '../theme/app_theme.dart';

class EpisodeTile extends StatefulWidget {
  final Episode episode;
  final WatchProgress? progress;
  final bool isPlaying;
  final VoidCallback onTap;

  const EpisodeTile({
    super.key,
    required this.episode,
    this.progress,
    this.isPlaying = false,
    required this.onTap,
  });

  @override
  State<EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<EpisodeTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isPlaying
                ? AppTheme.accent.withValues(alpha: 0.15)
                : _isHovered
                    ? AppTheme.surfaceLight
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.isPlaying
                ? Border.all(color: AppTheme.accent.withValues(alpha: 0.3))
                : null,
          ),
          child: Row(
            children: [
              // Episode number
              SizedBox(
                width: 36,
                child: Text(
                  widget.episode.episodeNumber.toString(),
                  style: TextStyle(
                    color: widget.isPlaying
                        ? AppTheme.accent
                        : AppTheme.textMuted,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Play icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: widget.isPlaying
                      ? AppTheme.accent
                      : AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: AppTheme.textPrimary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              // Episode info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.episode.fullDisplayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.isPlaying
                            ? AppTheme.accent
                            : AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (widget.progress != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: widget.progress!.progressPercent,
                                backgroundColor: AppTheme.progressBackground,
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                  AppTheme.accent,
                                ),
                                minHeight: 3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatDuration(widget.progress!.position),
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // Subtitle indicator
              if (widget.episode.subtitlePath != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Tooltip(
                    message: 'Untertitel verfügbar',
                    child: Icon(
                      Icons.subtitles_rounded,
                      size: 18,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}min';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
