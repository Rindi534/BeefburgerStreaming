import 'dart:io';
import 'package:flutter/material.dart';
import '../models/media_item.dart';
import '../theme/app_theme.dart';

class MediaCard extends StatefulWidget {
  final MediaItem item;
  final double? progressPercent;
  final VoidCallback onTap;

  const MediaCard({
    super.key,
    required this.item,
    this.progressPercent,
    required this.onTap,
  });

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _isHovered = false;
  // Touch-down feedback: on iPad there's no hover, so we drive the same
  // scale + play-icon overlay off a press state instead. On Windows both
  // states coexist harmlessly — a mouse-click briefly shows press-scale
  // on top of the already-scaled hover state (visually: a tiny squeeze
  // on click), which actually reads as nice tactile feedback.
  bool _isPressed = false;

  // The card is "active" (show scaled + play badge) on either hover OR
  // press. Hover is desktop-only, press covers the touch path on iPad.
  bool get _isActive => _isHovered || _isPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          transform: _isActive ? (Matrix4.identity()..setEntry(0, 0, 1.05)..setEntry(1, 1, 1.05)..setEntry(2, 2, 1.05)) : Matrix4.identity(),
          transformAlignment: Alignment.center,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildCoverImage(),
                      // Gradient overlay
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 60,
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
                        ),
                      ),
                      // Type badge
                      if (widget.item.type == MediaType.series)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${widget.item.totalEpisodes} Ep.',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      // Hover/press play icon — shown on desktop hover
                      // or during the touch press on iPad.
                      if (_isActive)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.accent.withValues(alpha: 0.9),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                      // Progress bar
                      if (widget.progressPercent != null &&
                          widget.progressPercent! > 0)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: widget.progressPercent!,
                            backgroundColor: AppTheme.progressBackground,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppTheme.accent,
                            ),
                            minHeight: 3,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (widget.item.type == MediaType.series)
                Text(
                  '${widget.item.seasons.length} Staffel${widget.item.seasons.length > 1 ? 'n' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage() {
    // Grid card is portrait; prefer cover.jpg, then fall back to the
    // other slots only if no cover was provided at all.
    final imagePath = widget.item.coverImagePath ??
        widget.item.thumbnailImagePath ??
        widget.item.bannerImagePath;
    if (imagePath != null) {
      final file = File(imagePath);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, e, s) => _buildPlaceholder(),
        );
      }
    }
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.surfaceLight,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.item.type == MediaType.movie
                  ? Icons.movie_rounded
                  : Icons.tv_rounded,
              size: 40,
              color: AppTheme.textMuted,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                widget.item.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
