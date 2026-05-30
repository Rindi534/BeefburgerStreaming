import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../models/watch_progress.dart';
import '../theme/app_theme.dart';

class ContinueWatchingSection extends StatefulWidget {
  final List<WatchProgress> items;
  final void Function(WatchProgress) onTap;
  /// Optional lookup from `mediaId` to the current library item's image
  /// paths. The card uses the cascade thumbnail → banner → cover so the
  /// user can provide a dedicated landscape image for this row without
  /// affecting the grid or the detail hero. Missing entries (removed
  /// media) fall back to the cover stored in the WatchProgress record.
  final ({String? thumbnail, String? banner, String? cover}) Function(
      String mediaId)? imageResolver;

  const ContinueWatchingSection({
    super.key,
    required this.items,
    required this.onTap,
    this.imageResolver,
  });

  @override
  State<ContinueWatchingSection> createState() =>
      _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState extends State<ContinueWatchingSection>
    with SingleTickerProviderStateMixin {
  // Mirror of `_SeasonChipBar`: side arrow buttons + visible scrollbar +
  // mouse-wheel→horizontal adapter so a long Weiterschauen row is
  // obviously scrollable instead of silently clipping on the right.
  final ScrollController _ctrl = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  // ─── Edge-bounce animation (wheel-over-end rubber-band) ───
  // Flutter's `pointerScroll` clamps at the edges — BouncingScroll-
  // Physics only rubber-bands on drag, not on wheel. To get the same
  // visual feel for mouse-wheel we drive a local animation here that
  // translates the list a few pixels past the edge and springs back
  // (Curves.elasticOut). Amount is accumulated while the user keeps
  // spinning the wheel against the wall.
  late final AnimationController _bounceCtrl;
  late Animation<double> _bounceAnim;
  double _bouncePx = 0;
  // Accumulator for overscroll pixels that have NOT yet produced a
  // visible bounce. Keeps the animation from firing on tiny edge
  // brushes — user must push noticeably past the edge before the
  // list visibly rubber-bands. Decays to 0 when the user pauses.
  double _pendingOverscroll = 0;
  DateTime _lastBounceKick = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_updateArrows);
    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 680),
    )..addStatusListener((status) {
        // Fresh state after each completed bounce — the pending bank
        // resets so a push in either direction has to build up from
        // zero again (prevents stale accumulation from a previous
        // locked-out session).
        if (status == AnimationStatus.completed) {
          _pendingOverscroll = 0;
          _bouncePx = 0;
        }
      });
    _bounceAnim =
        Tween<double>(begin: 0, end: 0).animate(_bounceCtrl);
    // Initial measurement once the list has laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void didUpdateWidget(covariant ContinueWatchingSection old) {
    super.didUpdateWidget(old);
    // Item count can change (episode finished → removed from list).
    // Remeasure after the next layout so arrows hide/show correctly.
    if (old.items.length != widget.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_updateArrows);
    _ctrl.dispose();
    _bounceCtrl.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!_ctrl.hasClients) return;
    final max = _ctrl.position.maxScrollExtent;
    final cur = _ctrl.position.pixels;
    // If there's nothing to scroll (everything fits), both arrows
    // must hide — regardless of current position. This is the case
    // we were missing before: on window resize or item removal
    // `maxScrollExtent` collapses to ≈0 but the scroll listener
    // doesn't fire (position didn't change), so arrows stayed.
    final nextLeft = max > 4 && cur > 4;
    final nextRight = max > 4 && cur < max - 4;
    if (nextLeft != _canLeft || nextRight != _canRight) {
      setState(() {
        _canLeft = nextLeft;
        _canRight = nextRight;
      });
    }
  }

  /// Animated scroll for the edge-arrow buttons — a button press
  /// should glide visibly. Used only for button taps, not for wheel.
  void _scrollBy(double delta) {
    if (!_ctrl.hasClients) return;
    final max = _ctrl.position.maxScrollExtent;
    final target = (_ctrl.position.pixels + delta).clamp(0.0, max);
    _ctrl.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Wheel scroll with rubber-band edge animation. Delta that
  /// actually moves the list goes through `pointerScroll`; delta
  /// that would push past an edge feeds the bounce animation.
  void _wheelScroll(double delta) {
    if (!_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final before = pos.pixels;
    final max = pos.maxScrollExtent;
    // How much delta can the list actually absorb?
    final wantTo = before + delta;
    final clamped = wantTo.clamp(0.0, max);
    final absorbed = clamped - before;
    final leftover = delta - absorbed;
    if (absorbed != 0) {
      pos.pointerScroll(absorbed);
    }
    if (leftover != 0 && max > 0) {
      _kickBounce(leftover);
    } else if (leftover != 0 && max == 0) {
      // Everything fits → no scrolling possible, but user still
      // spun the wheel. No bounce (there's nothing to scroll so
      // rubber-band would look weird) — just ignore.
    }
  }

  /// Play / extend the edge-bounce. Repeated kicks while animating
  /// push further out (with diminishing returns) so hammering the
  /// wheel feels alive instead of freezing a single bounce.
  void _kickBounce(double leftover) {
    // LOCK: while a bounce is playing, ignore new wheel input. Without
    // this, rapid wheel notches kept calling forward(from: 0) which
    // snapped the list back to 0 and restarted — the "ruckelig" feel.
    // User must wait one bounce-cycle before a new one can start.
    if (_bounceCtrl.isAnimating) return;
    // Sign convention: positive leftover = past right edge → list
    // should visually shift left (negative translate.x), so the
    // stretch is revealed on the right side. Negative leftover =
    // past left edge → list shifts right → gap on left. Symmetric.
    final dir = leftover > 0 ? -1.0 : 1.0;
    final now = DateTime.now();
    final sinceLast = now.difference(_lastBounceKick).inMilliseconds;
    _lastBounceKick = now;
    // If the user paused (or changed direction), reset the bank so
    // a fresh push has to build up again.
    if (sinceLast > 260 || (_bouncePx != 0 && _bouncePx.sign != dir)) {
      _pendingOverscroll = 0;
    }
    _pendingOverscroll += leftover.abs();

    // Deadzone: the first ~220 px of overscroll produce nothing —
    // that's roughly two wheel notches at the edge. Bounce only
    // starts after the user keeps pushing past that. "Viel später".
    const threshold = 360.0;
    if (_pendingOverscroll < threshold) return;
    final over = _pendingOverscroll - threshold;

    // Past the threshold, amplitude builds quickly so the spring has
    // visible reach (user wants a bigger, further bounce — not a
    // slow one). Higher cap + higher factor than before.
    final decay = sinceLast < 150 ? 0.55 : 0.0;
    final add = over * 0.18;
    final newAmount = (_bouncePx.abs() * decay + add).clamp(0.0, 72.0);
    if (newAmount < 8) return; // not worth animating yet
    _bouncePx = dir * newAmount;
    // 0 → peak → 0 in one flow. Without this the list used to SNAP
    // to the peak in a single frame and only animated back — that
    // was the "abrupt" feel. Both phases use easeOutCubic so
    // velocity is zero at the peak (no kink) and zero at rest.
    _bounceAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: _bouncePx)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 32, // shorter push-out
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: _bouncePx, end: 0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 68, // longer, gentler settle
      ),
    ]).animate(_bounceCtrl);
    _bounceCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text(
            'Weiterschauen',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ),
        SizedBox(
          height: 184, // card 180 + small bottom breathing room
          child: Stack(
            children: [
              // Mouse-wheel-over-row → horizontal scroll. We go through
              // the PointerSignalResolver so we "win" against the outer
              // page scrollable which would otherwise consume the same
              // event and scroll the page instead of the row.
              Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    GestureBinding.instance.pointerSignalResolver
                        .register(e, (ev) {
                      if (ev is PointerScrollEvent) {
                        // Route wheel through the position's own
                        // pointerScroll so BouncingScrollPhysics kicks
                        // in at the ends — wheel now rubber-bands
                        // exactly like drag. ×2.0 because one wheel
                        // notch is ~100 px but a card is ~260 px wide.
                        _wheelScroll(ev.scrollDelta.dy * 2.0);
                      }
                    });
                  }
                },
                // ScrollConfiguration enables click-and-drag with the
                // mouse on desktop (Flutter disables this by default
                // for mouse pointers) and hides the default scrollbar.
                // NotificationListener remeasures arrow visibility any
                // time the scroll metrics change (window resize, item
                // removal) — the plain scroll-listener only fires on
                // actual scrolling, so those two cases were the ones
                // where arrows got stuck.
                child: ScrollConfiguration(
                  behavior: _DragScrollBehavior(),
                  child: NotificationListener<ScrollMetricsNotification>(
                    onNotification: (_) {
                      _updateArrows();
                      return false;
                    },
                    // AnimatedBuilder drives the wheel-overscroll
                    // rubber-band: a Transform.translate nudges the
                    // whole list a few pixels past the edge and the
                    // ElasticOut curve springs it back.
                    child: AnimatedBuilder(
                      animation: _bounceAnim,
                      builder: (_, child) => Transform.translate(
                        offset: Offset(_bounceAnim.value, 0),
                        child: child,
                      ),
                      child: ListView.builder(
                      controller: _ctrl,
                      scrollDirection: Axis.horizontal,
                      // BouncingScrollPhysics handles drag-overscroll
                      // (finger past the edge). Wheel-overscroll is
                      // handled separately in `_wheelScroll` because
                      // `pointerScroll` clamps at the edges in Flutter.
                      physics: const BouncingScrollPhysics(
                        decelerationRate: ScrollDecelerationRate.fast,
                      ),
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      itemCount: widget.items.length,
                      itemBuilder: (context, index) {
                        final resolved = widget.imageResolver
                            ?.call(widget.items[index].mediaId);
                        return _ContinueWatchingCard(
                          progress: widget.items[index],
                          thumbnailImagePath: resolved?.thumbnail,
                          bannerImagePath: resolved?.banner,
                          coverImagePathOverride: resolved?.cover,
                          onTap: () => widget.onTap(widget.items[index]),
                        );
                      },
                    ),
                    ),
                  ),
                ),
              ),
              if (_canLeft)
                _buildEdgeArrow(alignLeft: true, onTap: () => _scrollBy(-320)),
              if (_canRight)
                _buildEdgeArrow(alignLeft: false, onTap: () => _scrollBy(320)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEdgeArrow({required bool alignLeft, required VoidCallback onTap}) {
    return Positioned(
      top: 0,
      bottom: 4,
      left: alignLeft ? 0 : null,
      right: alignLeft ? null : 0,
      width: 48,
      child: IgnorePointer(
        ignoring: false,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: alignLeft ? Alignment.centerLeft : Alignment.centerRight,
              end: alignLeft ? Alignment.centerRight : Alignment.centerLeft,
              colors: [
                AppTheme.background,
                AppTheme.background.withValues(alpha: 0.0),
              ],
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: Icon(
                  alignLeft ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
                  color: AppTheme.textSecondary,
                  size: 28,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContinueWatchingCard extends StatefulWidget {
  final WatchProgress progress;
  final String? thumbnailImagePath;
  final String? bannerImagePath;
  final String? coverImagePathOverride;
  final VoidCallback onTap;

  const _ContinueWatchingCard({
    required this.progress,
    required this.onTap,
    this.thumbnailImagePath,
    this.bannerImagePath,
    this.coverImagePathOverride,
  });

  @override
  State<_ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<_ContinueWatchingCard> {
  bool _isHovered = false;
  // Touch-press state so iPad gets the same scale feedback — hover
  // events never fire on a touchscreen. See MediaCard for the full
  // rationale; behavior on desktop is unchanged.
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final active = _isHovered || _isPressed;
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
          transform: active ? (Matrix4.identity()..setEntry(0, 0, 1.03)..setEntry(1, 1, 1.03)..setEntry(2, 2, 1.03)) : Matrix4.identity(),
          transformAlignment: Alignment.center,
          width: 280,
          margin: const EdgeInsets.only(right: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildImage(),
                // Gradient
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.9),
                      ],
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
                // Info
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          widget.progress.mediaTitle ?? 'Unbekannt',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.progress.episodeTitle != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            widget.progress.episodeTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: widget.progress.progressPercent,
                        backgroundColor: AppTheme.progressBackground,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppTheme.accent,
                        ),
                        minHeight: 3,
                      ),
                    ],
                  ),
                ),
                // Play icon on hover
                if (_isHovered)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 28,
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

  Widget _buildImage() {
    // Fallback cascade: thumbnail.jpg (dedicated continue-watching image)
    // → banner.jpg (landscape hero) → cover.jpg (portrait poster) → placeholder.
    // We also fall back to the WatchProgress's snapshot of the cover at
    // the time of watching, which covers the "media was removed from
    // library" case.
    final imagePath = widget.thumbnailImagePath ??
        widget.bannerImagePath ??
        widget.coverImagePathOverride ??
        widget.progress.coverImagePath;
    if (imagePath != null) {
      final file = File(imagePath);
      if (file.existsSync()) {
        // errorBuilder catches the race where the file is deleted between
        // existsSync() and the decoder actually reading it, or if it's
        // corrupt — instead of a red Flutter error widget the user sees the
        // normal placeholder.
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(),
        );
      }
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: AppTheme.surfaceLight,
      child: const Center(
        child: Icon(Icons.movie_rounded, size: 36, color: AppTheme.textMuted),
      ),
    );
  }
}

/// ScrollBehavior that enables click-and-drag with the mouse on desktop.
/// Flutter's default MaterialScrollBehavior excludes `PointerDeviceKind.mouse`
/// from `dragDevices`, which is why horizontal lists normally feel "dead"
/// under the cursor without a visible scrollbar. Enabling it makes the
/// Weiterschauen row (and the Staffel-Chip-Leiste using the same class)
/// feel native: grab anywhere and drag.
class _DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };

  // Hide the default scrollbar — we paint our own edge-arrow affordance
  // and support wheel + drag, so the bar is just visual noise.
  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}
