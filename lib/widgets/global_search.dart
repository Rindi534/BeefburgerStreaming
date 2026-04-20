import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/episode.dart';
import '../models/media_item.dart';
import '../providers/media_library_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../screens/detail_screen.dart';
import '../screens/player_screen.dart';
import '../theme/app_theme.dart';

/// One search hit. Three kinds are produced: [_MovieHit], [_SeriesHit] and
/// [_EpisodeHit]. The hit object carries everything the click-handler
/// needs to open the right screen, so the row widgets stay dumb.
sealed class _Hit {
  const _Hit();
}

class _MovieHit extends _Hit {
  final MediaItem item;
  const _MovieHit(this.item);
}

class _SeriesHit extends _Hit {
  final MediaItem item;
  const _SeriesHit(this.item);
}

class _EpisodeHit extends _Hit {
  final MediaItem series;
  final Episode episode;
  const _EpisodeHit(this.series, this.episode);
}

/// Global search field + dropdown for the Home-screen header.
///
/// Design notes:
/// - Uses an [OverlayEntry] for the result dropdown so it can float above
///   the (clipping) SliverAppBar / CustomScrollView without being cut off
///   by the app-bar's own bounds.
/// - Filtering happens synchronously on every keystroke over the already-
///   in-memory `library.items` list — cheap for any realistic home
///   library, and keeps the UI snappy. No debouncing needed.
/// - Click-handlers route through exactly the same `Navigator.push` that
///   the rest of the home/detail screens use, so watch-progress recording
///   (and therefore the "Weiterschauen" row) integrates automatically —
///   the player writes progress itself, the caller doesn't need to do
///   anything extra.
class GlobalSearchField extends ConsumerStatefulWidget {
  const GlobalSearchField({super.key});

  @override
  ConsumerState<GlobalSearchField> createState() => _GlobalSearchFieldState();
}

class _GlobalSearchFieldState extends ConsumerState<GlobalSearchField> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;
  String _query = '';
  // Captured by the outer LayoutBuilder so the dropdown matches the
  // field's exact rendered width (the SliverAppBar uses Expanded, so
  // the width depends on window size).
  double _fieldWidth = 420;

  // Per-row-type result caps. Keeps the dropdown short even on huge libs.
  static const int _capPerGroup = 8;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _removeOverlay();
    _ctrl.removeListener(_onTextChanged);
    _focus.removeListener(_onFocusChanged);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final q = _ctrl.text.trim();
    if (q == _query) return;
    setState(() => _query = q);
    if (q.isEmpty) {
      _removeOverlay();
    } else {
      _ensureOverlay();
      _overlay?.markNeedsBuild();
    }
  }

  void _onFocusChanged() {
    // Don't nuke the overlay the instant the field loses focus — that
    // would eat the tap that caused the blur. Navigation-on-click calls
    // [_closeAfterNavigate] explicitly instead.
    if (_focus.hasFocus && _query.isNotEmpty) {
      _ensureOverlay();
    }
  }

  void _ensureOverlay() {
    if (_overlay != null) return;
    _overlay = OverlayEntry(builder: _buildOverlay);
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  /// Called from a result tap. We want the dropdown to disappear before
  /// the navigation push animates, so the user doesn't see it hanging
  /// on top of the detail/player screen for a frame.
  void _closeAfterNavigate() {
    _removeOverlay();
    _ctrl.clear();
    _focus.unfocus();
    setState(() => _query = '');
  }

  // ── Search logic ──────────────────────────────────────────────────

  /// Scoring: prefix match beats substring match, and for episodes a
  /// series-title hit beats an episode-title hit. 0 = no match.
  ///
  /// The numbers are hand-picked so that, for the same query, a series
  /// whose title STARTS with the query always ranks above another
  /// series where the query is only buried in the middle — and both
  /// easily beat any episode-title-only hit.
  static int _titleScore(String title, String lq) {
    final t = title.toLowerCase();
    if (t == lq) return 130;
    if (t.startsWith(lq)) return 100;
    // Word-boundary match (e.g. "Bad" in "Breaking Bad") — cheap
    // approximation via `' $lq'`.
    if (t.contains(' $lq')) return 75;
    if (t.contains(lq)) return 50;
    return 0;
  }

  static int _episodeScore(MediaItem series, Episode ep, String lq) {
    final s = _titleScore(series.title, lq);
    final e = _titleScore(ep.title, lq);
    final c = ep.displayName.toLowerCase().contains(lq) ? 20 : 0;
    // Series-title contribution doubled so a generic substring hit
    // on the series ("Se" in "Seinfeld") beats a strong prefix hit
    // on an unrelated episode. c (SxxExx code) adds only a tie-break.
    final total = s * 2 + e + c;
    return total;
  }

  List<_Hit> _search(MediaLibraryState lib, String q) {
    if (q.isEmpty) return const [];
    final lq = q.toLowerCase();

    // Collect (score, hit) tuples first, then sort and cap per group.
    final movies = <({int score, _MovieHit hit})>[];
    final series = <({int score, _SeriesHit hit})>[];
    final episodes = <({int score, _EpisodeHit hit})>[];

    for (final item in lib.items) {
      if (item.type == MediaType.movie) {
        final s = _titleScore(item.title, lq);
        if (s > 0) movies.add((score: s, hit: _MovieHit(item)));
      } else {
        final ss = _titleScore(item.title, lq);
        if (ss > 0) series.add((score: ss, hit: _SeriesHit(item)));
        // Episode search now also matches the SERIES title — so
        // typing "Seinfeld" surfaces every Seinfeld episode, and
        // typing "Se" ranks Seinfeld episodes above accidental
        // substring hits in unrelated shows' episode names.
        for (final ep in item.allEpisodes) {
          final sc = _episodeScore(item, ep, lq);
          if (sc > 0) {
            episodes.add((score: sc, hit: _EpisodeHit(item, ep)));
          }
        }
      }
    }

    // Descending by score; stable enough that titles with the same
    // score keep scan order, which reads as "alphabetical-ish".
    movies.sort((a, b) => b.score.compareTo(a.score));
    series.sort((a, b) => b.score.compareTo(a.score));
    episodes.sort((a, b) => b.score.compareTo(a.score));

    return [
      ...movies.take(_capPerGroup).map((e) => e.hit),
      ...series.take(_capPerGroup).map((e) => e.hit),
      ...episodes.take(_capPerGroup).map((e) => e.hit),
    ];
  }

  // ── Navigation handlers — must match Home/Detail exactly so the
  //    player writes watch-progress under the right mediaId. ────────

  void _onHitTap(_Hit hit) {
    switch (hit) {
      case _MovieHit(:final item):
        _playMovie(item);
      case _SeriesHit(:final item):
        _openSeriesDetail(item);
      case _EpisodeHit(:final series, :final episode):
        _playEpisode(series, episode);
    }
  }

  void _playMovie(MediaItem item) {
    if (item.movieFilePath == null) return;
    final progress = ref
        .read(watchProgressProvider.notifier)
        .getProgress(item.movieFilePath!);
    final nav = Navigator.of(context);
    _closeAfterNavigate();
    nav.push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        filePath: item.movieFilePath!,
        title: item.title,
        mediaId: item.id,
        coverImagePath: item.coverImagePath,
        startPosition: progress != null && !progress.isCompleted
            ? progress.position
            : null,
      ),
    ));
  }

  void _openSeriesDetail(MediaItem item) {
    final nav = Navigator.of(context);
    _closeAfterNavigate();
    nav.push(MaterialPageRoute(
      builder: (_) => DetailScreen(mediaItem: item),
    ));
  }

  void _playEpisode(MediaItem series, Episode episode) {
    // Mirrors DetailScreen._playEpisode so playback from search supports
    // auto-next-episode and resume-from-last-position identically.
    final allEpisodes = series.allEpisodes;
    final currentIndex =
        allEpisodes.indexWhere((e) => e.filePath == episode.filePath);
    final nextEpisode =
        currentIndex >= 0 && currentIndex < allEpisodes.length - 1
            ? allEpisodes[currentIndex + 1]
            : null;
    final progress = ref
        .read(watchProgressProvider.notifier)
        .getProgress(episode.filePath);

    final nav = Navigator.of(context);
    _closeAfterNavigate();
    nav.push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        filePath: episode.filePath,
        title: series.title,
        episodeTitle: episode.fullDisplayName,
        mediaId: series.id,
        coverImagePath: series.coverImagePath,
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
    ));
  }

  // ── UI ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder captures the actual rendered width of the slot the
    // SliverAppBar gives us, so the dropdown can be sized to match.
    // Esc → clear + blur. Useful when the dropdown is covering something
    // behind it and the user wants it gone without scrolling away.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite &&
            (constraints.maxWidth - _fieldWidth).abs() > 0.5) {
          // Next frame — can't mutate state during layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _fieldWidth = constraints.maxWidth);
            _overlay?.markNeedsBuild();
          });
        }
        return _buildShortcutsShell();
      },
    );
  }

  Widget _buildShortcutsShell() {
    return CompositedTransformTarget(
      link: _link,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): _DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _DismissIntent: CallbackAction<_DismissIntent>(
              onInvoke: (_) {
                _closeAfterNavigate();
                return null;
              },
            ),
          },
          child: _buildField(),
        ),
      ),
    );
  }

  Widget _buildField() {
    return SizedBox(
      height: 42,
      child: TextField(
        controller: _ctrl,
        focusNode: _focus,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 15,
        ),
        cursorColor: AppTheme.accent,
        decoration: InputDecoration(
          hintText: 'Suche nach Filmen, Serien oder Folgen…',
          hintStyle: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 14,
          ),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: AppTheme.textSecondary,
            size: 20,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppTheme.textSecondary,
                    size: 18,
                  ),
                  splashRadius: 18,
                  onPressed: _closeAfterNavigate,
                  tooltip: 'Leeren',
                ),
          filled: true,
          fillColor: AppTheme.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.divider, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.divider, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppTheme.accent.withValues(alpha: 0.6), width: 1.4),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    // Re-read library on every rebuild so newly-scanned media appears
    // without the user having to re-type the query.
    final library = ref.read(mediaLibraryProvider);
    final hits = _search(library, _query);

    final width = _fieldWidth.clamp(320.0, 720.0);

    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        // 46 = field height (42) + small gap (4). Anchored to the field's
        // top-left so the dropdown "grows" from directly under the input.
        offset: const Offset(0, 46),
        child: TapRegion(
          // Any tap OUTSIDE the dropdown or the field closes the dropdown
          // but keeps whatever they typed (so refocusing reopens it).
          onTapOutside: (_) {
            _focus.unfocus();
            _removeOverlay();
          },
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 520),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.divider, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0xAA000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: hits.isEmpty
                  ? _buildEmpty()
                  : _buildResults(hits),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
      child: Row(
        children: const [
          Icon(Icons.search_off_rounded,
              color: AppTheme.textMuted, size: 20),
          SizedBox(width: 10),
          Text(
            'Keine Treffer',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(List<_Hit> hits) {
    // Group headers (Filme / Serien / Folgen) are inserted inline as the
    // hit-types switch. Saves a parallel data structure for grouping.
    final rows = <Widget>[];
    _Hit? prev;
    for (final h in hits) {
      if (prev == null || prev.runtimeType != h.runtimeType) {
        rows.add(_groupHeader(_labelFor(h)));
      }
      rows.add(_buildRow(h));
      prev = h;
    }
    return Scrollbar(
      thumbVisibility: false,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 4),
        shrinkWrap: true,
        children: rows,
      ),
    );
  }

  String _labelFor(_Hit h) => switch (h) {
        _MovieHit() => 'Filme',
        _SeriesHit() => 'Serien',
        _EpisodeHit() => 'Folgen',
      };

  Widget _groupHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildRow(_Hit hit) {
    return switch (hit) {
      _MovieHit(:final item) => _ResultRow(
          imagePath: item.coverImagePath,
          portrait: true,
          title: item.title,
          subtitle: 'Film',
          icon: Icons.movie_rounded,
          onTap: () => _onHitTap(hit),
        ),
      _SeriesHit(:final item) => _ResultRow(
          imagePath: item.coverImagePath,
          portrait: true,
          title: item.title,
          subtitle: item.totalEpisodes == 1
              ? 'Serie · 1 Folge'
              : 'Serie · ${item.totalEpisodes} Folgen',
          icon: Icons.playlist_play_rounded,
          onTap: () => _onHitTap(hit),
        ),
      _EpisodeHit(:final series, :final episode) => _ResultRow(
          // Episodes use the landscape thumbnail (the same image the
          // Weiterschauen row uses) so the visual distinction from the
          // portrait cover rows above is immediate.
          imagePath: series.thumbnailImagePath ??
              series.bannerImagePath ??
              series.coverImagePath,
          portrait: false,
          title: '${series.title} · ${episode.displayName}',
          subtitle: episode.title,
          icon: Icons.play_circle_outline_rounded,
          onTap: () => _onHitTap(hit),
        ),
    };
  }
}

/// A single clickable result row. Kept local to this file — nothing else
/// in the app has this exact layout.
class _ResultRow extends StatefulWidget {
  final String? imagePath;
  final bool portrait;
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _ResultRow({
    required this.imagePath,
    required this.portrait,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Portrait (cover): 36×52 tile. Landscape (episode thumb): 64×36.
    final double imgW = widget.portrait ? 36 : 64;
    final double imgH = widget.portrait ? 52 : 36;

    Widget imageWidget;
    final path = widget.imagePath;
    if (path != null && File(path).existsSync()) {
      imageWidget = Image.file(
        File(path),
        width: imgW,
        height: imgH,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _placeholder(imgW, imgH),
      );
    } else {
      imageWidget = _placeholder(imgW, imgH);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: _hover ? AppTheme.cardHover : Colors.transparent,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: imageWidget,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(widget.icon,
                  size: 18, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder(double w, double h) {
    return Container(
      width: w,
      height: h,
      color: AppTheme.surfaceLight,
      child: const Icon(
        Icons.image_not_supported_rounded,
        size: 16,
        color: AppTheme.textMuted,
      ),
    );
  }
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}
