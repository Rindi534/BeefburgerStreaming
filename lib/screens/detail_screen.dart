import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/media_item.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import '../providers/watch_progress_provider.dart';
import '../widgets/episode_tile.dart';
import '../theme/app_theme.dart';
import 'player_screen.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final MediaItem mediaItem;

  const DetailScreen({super.key, required this.mediaItem});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late int _selectedSeason;
  // Controller for the horizontal season chip list. Kept alive across
  // rebuilds so the scroll position (and the arrow-button hit tests)
  // don't jump when the user picks a season and the list repaints.
  final ScrollController _seasonScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _selectedSeason = _initialSeason();
  }

  @override
  void dispose() {
    _seasonScroll.dispose();
    super.dispose();
  }

  /// Pick the season the user is most likely to want to see first:
  /// - If there's an in-progress / queued "Weiterschauen" episode, jump to
  ///   that season so they don't have to tab over.
  /// - Otherwise fall back to the lowest-numbered season.
  ///
  /// We can't use `_findContinueWatchingEpisode` here because it needs a
  /// `WidgetRef`, and `initState` doesn't have `ref` yet on ConsumerState in
  /// all Riverpod versions — but the notifier is readable via `ref.read`,
  /// which IS available on ConsumerState. Keep logic in sync with that
  /// method (in-progress first, then queued-at-zero fallback).
  int _initialSeason() {
    final seasons = widget.mediaItem.seasons;
    if (seasons.isEmpty) return 1;
    final fallback = seasons.first.number;

    final allEpisodes = widget.mediaItem.allEpisodes;
    if (allEpisodes.isEmpty) return fallback;

    final notifier = ref.read(watchProgressProvider.notifier);

    // Pass 1: most recently watched in-progress episode.
    WatchProgress? latest;
    Episode? latestEp;
    for (final ep in allEpisodes) {
      final p = notifier.getProgress(ep.filePath);
      if (p == null || p.isCompleted || !p.hasStarted) continue;
      if (latest == null || p.lastWatched.isAfter(latest.lastWatched)) {
        latest = p;
        latestEp = ep;
      }
    }

    // Pass 2: queued (position == 0) fallback.
    if (latestEp == null) {
      for (final ep in allEpisodes) {
        final p = notifier.getProgress(ep.filePath);
        if (p == null || p.isCompleted) continue;
        if (p.position != Duration.zero) continue;
        if (latest == null || p.lastWatched.isAfter(latest.lastWatched)) {
          latest = p;
          latestEp = ep;
        }
      }
    }

    return latestEp?.seasonNumber ?? fallback;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(watchProgressProvider);
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 800;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Hero header
          SliverAppBar(
            expandedHeight: isWide ? 350 : 250,
            pinned: true,
            backgroundColor: AppTheme.background,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _buildHeaderImage(),
                  // Gradient overlay
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          AppTheme.background.withValues(alpha: 0.6),
                          AppTheme.background,
                        ],
                        stops: const [0.0, 0.6, 1.0],
                      ),
                    ),
                  ),
                  // Title at bottom
                  Positioned(
                    bottom: 16,
                    left: 20,
                    right: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.mediaItem.title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                fontSize: isWide ? 36 : 28,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${widget.mediaItem.seasons.length} Staffel${widget.mediaItem.seasons.length > 1 ? 'n' : ''} · ${widget.mediaItem.totalEpisodes} Episoden',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Season selector — horizontally scrollable with visible
          // scrollbar and arrow buttons on both ends so a user with 10+
          // seasons doesn't have to guess that the list is scrollable.
          if (widget.mediaItem.seasons.length > 1)
            SliverToBoxAdapter(
              child: _buildSeasonSelector(),
            ),

          // Play / Continue watching button
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: SizedBox(
                width: double.infinity,
                child: _buildPlayButton(ref),
              ),
            ),
          ),

          // Episode list
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 40),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final episodes = _currentEpisodes;
                  if (index >= episodes.length) return null;
                  final episode = episodes[index];
                  final progress = ref
                      .read(watchProgressProvider.notifier)
                      .getProgress(episode.filePath);

                  return EpisodeTile(
                    episode: episode,
                    progress: progress,
                    onTap: () => _playEpisode(episode),
                  );
                },
                childCount: _currentEpisodes.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Episode> get _currentEpisodes {
    try {
      return widget.mediaItem.seasons
          .firstWhere((s) => s.number == _selectedSeason)
          .episodes;
    } catch (_) {
      return [];
    }
  }

  void _playEpisode(Episode episode) {
    // Use ALL episodes across ALL seasons for cross-season navigation
    final allEpisodes = widget.mediaItem.allEpisodes;
    final currentIndex = allEpisodes.indexWhere((e) => e.filePath == episode.filePath);
    final nextEpisode =
        currentIndex >= 0 && currentIndex < allEpisodes.length - 1
            ? allEpisodes[currentIndex + 1]
            : null;

    // Get progress for resume
    final progress = ref
        .read(watchProgressProvider.notifier)
        .getProgress(episode.filePath);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          filePath: episode.filePath,
          title: widget.mediaItem.title,
          episodeTitle: episode.fullDisplayName,
          mediaId: widget.mediaItem.id,
          coverImagePath: widget.mediaItem.coverImagePath,
          subtitlePath: episode.subtitlePath,
          nextEpisodeFilePath: nextEpisode?.filePath,
          nextEpisodeTitle: nextEpisode?.fullDisplayName,
          nextEpisodeSubtitlePath: nextEpisode?.subtitlePath,
          startPosition: progress != null && !progress.isCompleted
              ? progress.position
              : null,
          allEpisodes: allEpisodes,
          currentEpisodeIndex: currentIndex >= 0 ? currentIndex : 0,
        ),
      ),
    );
  }

  /// Find the episode to continue watching (across all seasons).
  /// Returns (episode, progress) or null if nothing to continue.
  (Episode, WatchProgress)? _findContinueWatchingEpisode(WidgetRef ref) {
    final allEpisodes = widget.mediaItem.allEpisodes;
    final notifier = ref.read(watchProgressProvider.notifier);

    // Find episode with most recent in-progress watch data
    WatchProgress? latestProgress;
    Episode? latestEpisode;

    for (final ep in allEpisodes) {
      final progress = notifier.getProgress(ep.filePath);
      if (progress != null && !progress.isCompleted && progress.hasStarted) {
        if (latestProgress == null ||
            progress.lastWatched.isAfter(latestProgress.lastWatched)) {
          latestProgress = progress;
          latestEpisode = ep;
        }
      }
    }

    // Also check for queued episodes (position == 0, created by _queueNextEpisode)
    if (latestEpisode == null) {
      for (final ep in allEpisodes) {
        final progress = notifier.getProgress(ep.filePath);
        if (progress != null &&
            !progress.isCompleted &&
            progress.position == Duration.zero) {
          if (latestProgress == null ||
              progress.lastWatched.isAfter(latestProgress.lastWatched)) {
            latestProgress = progress;
            latestEpisode = ep;
          }
        }
      }
    }

    if (latestEpisode != null && latestProgress != null) {
      return (latestEpisode, latestProgress);
    }
    return null;
  }

  Widget _buildPlayButton(WidgetRef ref) {
    final continueInfo = _findContinueWatchingEpisode(ref);

    if (continueInfo != null) {
      final (episode, _) = continueInfo;
      return ElevatedButton.icon(
        onPressed: () => _playEpisode(episode),
        icon: const Icon(Icons.play_arrow_rounded, size: 24),
        label: Text('Weiterschauen · ${episode.fullDisplayName}'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    // No continue watching — play from the very beginning (S01E01)
    return ElevatedButton.icon(
      onPressed: () => _playFromBeginning(),
      icon: const Icon(Icons.play_arrow_rounded, size: 24),
      label: const Text('Abspielen'),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  void _playFromBeginning() {
    // Always start with the first episode of the first (lowest) season
    final allEpisodes = widget.mediaItem.allEpisodes;
    if (allEpisodes.isEmpty) return;
    _playEpisode(allEpisodes.first);
  }

  /// Horizontally scrollable season chips with:
  /// - a visible Scrollbar (so it's obvious the list CAN scroll)
  /// - left/right arrow buttons that only appear when there's
  ///   actually off-screen content in that direction (so a 3-season
  ///   list doesn't show useless nav buttons)
  /// - mouse-wheel → horizontal scroll adapter (vertical wheels are
  ///   the norm on Windows desktops and without this you can't wheel
  ///   through the seasons at all — you'd have to click-drag)
  ///
  /// The list itself uses a tight `ListView.builder` so rendering cost
  /// stays constant even with 40-season daily-soap libraries.
  Widget _buildSeasonSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return _SeasonChipBar(
            seasons: widget.mediaItem.seasons,
            selected: _selectedSeason,
            onSelected: (n) => setState(() => _selectedSeason = n),
            controller: _seasonScroll,
            maxWidth: constraints.maxWidth,
          );
        },
      ),
    );
  }

  Widget _buildHeaderImage() {
    // Header is the landscape hero above the episode list. Fallback order:
    // banner (purpose-built landscape) → cover (portrait, cropped) →
    // thumbnail (may be portrait or landscape, last resort). No image → placeholder.
    final imagePath = widget.mediaItem.bannerImagePath ??
        widget.mediaItem.coverImagePath ??
        widget.mediaItem.thumbnailImagePath;
    if (imagePath != null) {
      final file = File(imagePath);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          // Guard against race / corrupt-file — fall back to placeholder
          // instead of letting Flutter render a red error widget.
          errorBuilder: (_, __, ___) => _headerPlaceholder(),
        );
      }
    }
    return _headerPlaceholder();
  }

  Widget _headerPlaceholder() {
    return Container(
      color: AppTheme.surface,
      child: const Center(
        child: Icon(Icons.tv_rounded, size: 64, color: AppTheme.textMuted),
      ),
    );
  }
}

/// Internal widget for the detail screen's season chips. Split out so
/// it can hold its own state (arrow visibility tied to scroll position)
/// without polluting [_DetailScreenState].
class _SeasonChipBar extends StatefulWidget {
  final List<Season> seasons;
  final int selected;
  final void Function(int) onSelected;
  final ScrollController controller;
  final double maxWidth;

  const _SeasonChipBar({
    required this.seasons,
    required this.selected,
    required this.onSelected,
    required this.controller,
    required this.maxWidth,
  });

  @override
  State<_SeasonChipBar> createState() => _SeasonChipBarState();
}

class _SeasonChipBarState extends State<_SeasonChipBar>
    with SingleTickerProviderStateMixin {
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  // Wheel-edge rubber-band: Flutter's `pointerScroll` clamps on wheel
  // events, so BouncingScrollPhysics (which only handles drag) never
  // gets a chance. We animate a Transform.translate overlay instead.
  late final AnimationController _bounceCtrl;
  late Animation<double> _bounceAnim;
  double _bouncePx = 0;
  // Overscroll accumulator — see twin in continue_watching.dart.
  double _pendingOverscroll = 0;
  DateTime _lastBounceKick = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateArrows);
    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _pendingOverscroll = 0;
          _bouncePx = 0;
        }
      });
    _bounceAnim = Tween<double>(begin: 0, end: 0).animate(_bounceCtrl);
    // Initial measurement after first layout — `hasClients` is false
    // until ListView attaches to the controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void didUpdateWidget(covariant _SeasonChipBar old) {
    super.didUpdateWidget(old);
    // Season count / width may have changed — re-measure.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateArrows);
    _bounceCtrl.dispose();
    super.dispose();
  }

  /// Edge-bounce kick for wheel-over-end. See the twin in
  /// `continue_watching.dart` for rationale.
  void _kickBounce(double leftover) {
    // Lock: see twin in continue_watching.dart — no restarts while
    // the spring is still returning.
    if (_bounceCtrl.isAnimating) return;
    final dir = leftover > 0 ? -1.0 : 1.0;
    final now = DateTime.now();
    final sinceLast = now.difference(_lastBounceKick).inMilliseconds;
    _lastBounceKick = now;
    if (sinceLast > 260 || (_bouncePx != 0 && _bouncePx.sign != dir)) {
      _pendingOverscroll = 0;
    }
    _pendingOverscroll += leftover.abs();

    // Deadzone: require real push past the edge before chips visibly
    // shift. Chips are small — a high-frequency micro-bounce looked
    // "unclean"; holding the wheel through the threshold makes the
    // bounce feel intentional.
    const threshold = 260.0;
    if (_pendingOverscroll < threshold) return;
    final over = _pendingOverscroll - threshold;

    final decay = sinceLast < 150 ? 0.55 : 0.0;
    // Chips are smaller than Weiterschauen cards → keep cap a tad
    // lower, but clearly bigger push than before so the bounce
    // "reaches further".
    final add = over * 0.19;
    final newAmount = (_bouncePx.abs() * decay + add).clamp(0.0, 64.0);
    if (newAmount < 7) return;
    _bouncePx = dir * newAmount;
    // 0 → peak → 0 sequence so the list doesn't snap out in one
    // frame. See continue_watching.dart for the rationale.
    _bounceAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0, end: _bouncePx)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 32,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: _bouncePx, end: 0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 68,
      ),
    ]).animate(_bounceCtrl);
    _bounceCtrl.forward(from: 0);
  }

  void _updateArrows() {
    if (!mounted || !widget.controller.hasClients) return;
    final pos = widget.controller.position;
    // Hide BOTH arrows when everything fits (maxScrollExtent≈0). The
    // plain scroll listener doesn't fire on resize / season-count
    // changes because `pixels` stays at 0 — that was the "arrow stays
    // stuck" bug.
    final left = pos.maxScrollExtent > 4 && pos.pixels > 4;
    final right =
        pos.maxScrollExtent > 4 && pos.pixels < pos.maxScrollExtent - 4;
    if (left != _canScrollLeft || right != _canScrollRight) {
      setState(() {
        _canScrollLeft = left;
        _canScrollRight = right;
      });
    }
  }

  /// Paginate-scroll by roughly a viewport width — feels much better
  /// than jumping N chips because chip widths vary with label length.
  void _scrollBy(double delta) {
    if (!widget.controller.hasClients) return;
    final target = (widget.controller.offset + delta).clamp(
      0.0,
      widget.controller.position.maxScrollExtent,
    );
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Chip list — Listener routes mouse-wheel events through the
    // PointerSignalResolver so this row "wins" against the outer page
    // scrollable; without that, wheel-over-chip-bar just scrolls the
    // whole detail page.
    final chipList = Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && widget.controller.hasClients) {
          GestureBinding.instance.pointerSignalResolver.register(event, (ev) {
            if (ev is! PointerScrollEvent) return;
            final dy = ev.scrollDelta.dy;
            final dx = ev.scrollDelta.dx;
            // Prefer the axis with the larger delta. `dx` is non-zero
            // on real horizontal wheels / trackpads; `dy` is the normal
            // vertical wheel we're re-mapping.
            final rawDelta = dx.abs() > dy.abs() ? dx : dy;
            if (rawDelta == 0) return;
            // Chips are narrow (~80–120 px) — raw wheel delta rushes
            // past them. Scale down so one notch moves roughly one chip.
            final delta = rawDelta * 0.45;
            // Split delta: absorbed moves the list, leftover feeds the
            // edge-bounce animation (pointerScroll on its own clamps
            // hard at the edge, no rubber-band).
            final pos = widget.controller.position;
            final before = pos.pixels;
            final max = pos.maxScrollExtent;
            final clamped = (before + delta).clamp(0.0, max);
            final absorbed = clamped - before;
            final leftover = delta - absorbed;
            if (absorbed != 0) pos.pointerScroll(absorbed);
            if (leftover != 0 && max > 0) _kickBounce(leftover);
          });
        }
      },
      // Drag-to-scroll enabled; visible scrollbar removed. Edge arrows
      // below still appear when there's overflow and hide when not.
      // NotificationListener remeasures on layout/metrics changes —
      // the regular scroll-listener misses resize & count changes.
      child: ScrollConfiguration(
        behavior: _DragScrollBehavior(),
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _updateArrows();
            return false;
          },
          // AnimatedBuilder drives the wheel-edge rubber-band: the
          // list itself can't overscroll on wheel (Flutter clamps),
          // so we shift the WHOLE list a few px via Transform and
          // spring it back with ElasticOut.
          child: AnimatedBuilder(
            animation: _bounceAnim,
            builder: (_, child) => Transform.translate(
              offset: Offset(_bounceAnim.value, 0),
              child: child,
            ),
            child: ListView.builder(
          controller: widget.controller,
          scrollDirection: Axis.horizontal,
          // BouncingScrollPhysics handles drag-overscroll. Wheel-
          // overscroll is handled by the AnimatedBuilder above because
          // `pointerScroll` clamps at the edges in Flutter.
          physics: const BouncingScrollPhysics(
            decelerationRate: ScrollDecelerationRate.fast,
          ),
          padding: EdgeInsets.zero,
          itemCount: widget.seasons.length,
          itemBuilder: (context, i) {
            final season = widget.seasons[i];
            final isSelected = season.number == widget.selected;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(season.displayName),
                selected: isSelected,
                onSelected: (_) => widget.onSelected(season.number),
                selectedColor: AppTheme.accent,
                backgroundColor: AppTheme.surface,
                labelStyle: TextStyle(
                  color: isSelected ? Colors.white : AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                side: BorderSide.none,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
            );
          },
          ),
          ),
        ),
      ),
    );

    return SizedBox(
      // Fixed height keeps the list from stretching the slivers
      // vertically. Scrollbar is gone, so chip height (~36) + slack.
      height: 42,
      child: Stack(
        children: [
          Positioned.fill(child: chipList),
          // Fade + arrow on the left, only when there's content to
          // the left of the viewport.
          if (_canScrollLeft)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _buildEdgeArrow(
                icon: Icons.chevron_left_rounded,
                onPressed: () => _scrollBy(-widget.maxWidth * 0.7),
                alignment: Alignment.centerLeft,
              ),
            ),
          if (_canScrollRight)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: _buildEdgeArrow(
                icon: Icons.chevron_right_rounded,
                onPressed: () => _scrollBy(widget.maxWidth * 0.7),
                alignment: Alignment.centerRight,
              ),
            ),
        ],
      ),
    );
  }

  /// Arrow button with a gradient fade behind it so the chip underneath
  /// appears to "slide under" the arrow instead of abruptly disappearing.
  /// Gradient matches the screen background so the fade reads naturally.
  Widget _buildEdgeArrow({
    required IconData icon,
    required VoidCallback onPressed,
    required Alignment alignment,
  }) {
    final isLeft = alignment == Alignment.centerLeft;
    return IgnorePointer(
      ignoring: false,
      child: Container(
        width: 48,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: isLeft ? Alignment.centerRight : Alignment.centerLeft,
            end: isLeft ? Alignment.centerLeft : Alignment.centerRight,
            colors: [
              AppTheme.background.withValues(alpha: 0.0),
              AppTheme.background,
            ],
            stops: const [0.0, 0.7],
          ),
        ),
        alignment: alignment,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(icon,
                  size: 28, color: AppTheme.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Enables mouse click-and-drag for horizontal scrollables and hides the
/// default scrollbar. Paired with edge-arrow overlays that auto-hide when
/// there's nothing to scroll to. See the same class in
/// `widgets/continue_watching.dart` for rationale.
class _DragScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };

  @override
  Widget buildScrollbar(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}
