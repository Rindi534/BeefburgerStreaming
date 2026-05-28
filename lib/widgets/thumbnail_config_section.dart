import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/media_item.dart';
import '../models/media_metadata.dart';
import '../providers/media_history_provider.dart';
import '../providers/media_library_provider.dart';
import '../services/thumbnail_service.dart';
import '../theme/app_theme.dart';

/// "Vorschaubilder-Konfig" section on the Settings screen.
///
/// Revised in 1.4.2: the global "Cache für entfernte Medien behalten"
/// toggle is gone. It duplicated + silently overwrote the per-item
/// keep-flags, which made the mental model confusing ("what does the
/// toggle do if the flag is the source of truth?"). The toggle is
/// replaced by two explicit bulk-action buttons inside the keep-flag
/// section — one-shot actions, not a persistent mode.
///
/// Two collapsible subsections:
///
/// 1. **Für Behaltung geflagt** — per-item flag list. Shows BOTH
///    current and archive. The flag is the SOLE cleanup rule: on =
///    cache survives orphan prune, off = cache disappears when the
///    file does. Two bulk buttons at the top: "Alle flaggen" and
///    "Alle Flags entfernen & Archiv säubern".
///
/// 2. **Cache einzeln zurücksetzen** — expandable tree for both
///    current AND archive items. Per-series inner scroll when
///    expanded. Reset actions remove the node from the tree
///    immediately (tree reflects cache state, not library state);
///    nodes reappear when a fresh cache gets built. In 1.4.2 manual
///    resets no longer auto-regenerate on the next scan — they are
///    routed through the change-detection dialog (Variante A)
///    exactly like folder-detected changes.
class ThumbnailConfigSection extends ConsumerWidget {
  const ThumbnailConfigSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        _KeepFlagsExpansion(),
        SizedBox(height: 12),
        _ResetTreeExpansion(),
      ],
    );
  }
}

// ───────────────────────── Keep flags (aktuelle + Archiv) ─────────────────────────

class _KeepFlagsExpansion extends ConsumerWidget {
  const _KeepFlagsExpansion();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(mediaLibraryProvider);
    final history = ref.watch(mediaHistoryProvider);

    // Only show items that ACTUALLY have at least one cached
    // thumbnail. The keep-flag controls whether the cache survives
    // orphan cleanup — so it's nonsense to offer a flag for an item
    // whose cache is empty in the first place. After "Cache leeren"
    // this list correctly empties out instead of dangling former
    // entries the user already wiped.
    final cached = library.pathsWithCache;
    bool hasAnyCache(MediaItem item) {
      if (item.type == MediaType.movie) {
        return item.movieFilePath != null &&
            cached.contains(item.movieFilePath);
      }
      return item.allEpisodes.any((e) => cached.contains(e.filePath));
    }

    final currentIds = {for (final i in library.items) i.id};
    final current = [
      for (final i in library.items)
        if (hasAnyCache(i)) i,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final archive = history
        .where((h) =>
            !currentIds.contains(h.mediaId) &&
            h.allVideoPaths.any(cached.contains))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    return _Card(
      child: ExpansionTile(
        iconColor: AppTheme.textSecondary,
        collapsedIconColor: AppTheme.textSecondary,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: _leadingIcon(Icons.flag_rounded),
        title: const Text(
          'Für Behaltung geflagt',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: const Text(
          'Nur Medien mit vorhandenen Vorschaubildern können geflaggt werden. '
          'Geflaggte Medien überleben jede Aktualisierung, ungeflaggte werden '
          'aufgeräumt sobald die Dateien weg sind.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
        ),
        children: [
          const _BulkActionsRow(),
          _Subheader(title: 'Aktuelle Medien (${current.length})'),
          if (current.isEmpty)
            const _EmptyHint(
                'Keine Medien mit Vorschaubildern — Cache wurde entweder geleert oder noch nicht erzeugt'),
          ..._withDividers([
            for (final item in current)
              _CurrentItemFlagRow(item: item, history: history),
          ]),
          const SizedBox(height: 8),
          _Subheader(title: 'Archiv (${archive.length})'),
          if (archive.isEmpty)
            const _EmptyHint(
                'Keine archivierten Einträge mit Vorschaubildern'),
          ..._withDividers([
            for (final entry in archive) _ArchiveItemRow(entry: entry),
          ]),
        ],
      ),
    );
  }
}

class _CurrentItemFlagRow extends ConsumerWidget {
  final MediaItem item;
  final List<MediaMetadata> history;

  const _CurrentItemFlagRow({required this.item, required this.history});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = history.where((h) => h.mediaId == item.id).firstOrNull;
    final flagged = meta?.keepCache ?? false;
    return _HoverRow(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            Icon(
              item.type == MediaType.series
                  ? Icons.tv_rounded
                  : Icons.movie_rounded,
              size: 18,
              color: AppTheme.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.title,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Switch(
              value: flagged,
              activeThumbColor: AppTheme.accent,
              activeTrackColor: AppTheme.accent.withValues(alpha: 0.4),
              // NOTE: we do NOT call refresh() here. Flipping a keep-
              // flag doesn't change library contents — it only changes
              // whether orphan cleanup will spare this item later.
              // Calling scanLibrary would re-enter _generateThumbnails,
              // which under the right timing (e.g. initial gen still
              // finishing) regenerated caches for the just-flagged
              // movie from scratch. The UI updates anyway because it
              // watches mediaHistoryProvider.
              onChanged: (v) => ref
                  .read(mediaHistoryProvider.notifier)
                  .setKeepCache(item.id, v),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArchiveItemRow extends ConsumerWidget {
  final MediaMetadata entry;
  const _ArchiveItemRow({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _HoverRow(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            Icon(
              entry.typeIndex == MediaType.series.index
                  ? Icons.tv_rounded
                  : Icons.movie_rounded,
              size: 18,
              color: AppTheme.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                entry.title,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // No flag-toggle here: an entry is only in the archive
            // *because* its flag is on — toggling off would just mean
            // "clean me up", which the "Löschen"-button does more
            // clearly. Partial resets happen in the tree below.
            IconButton(
              tooltip: 'Aus Archiv entfernen (Cache + Eintrag löschen)',
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppTheme.textMuted, size: 20),
              onPressed: () async {
                final ok = await _confirmDelete(context, entry.title);
                if (ok != true) return;
                await ThumbnailService.instance
                    .clearCacheForPaths(entry.allVideoPaths);
                await ref
                    .read(mediaHistoryProvider.notifier)
                    .removeEntry(entry.mediaId);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String title) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Eintrag löschen?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '„$title" wird aus dem Archiv entfernt und der dazugehörige '
          'Vorschaubild-Cache gelöscht.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Per-item reset tree ─────────────────────────

/// Uniform shape the reset tree uses so current + archive render
/// identically. Current items come from `MediaItem`, archive items
/// come from the history snapshot JSON.
class _TreeSeries {
  final String key;
  final String title;
  final bool isArchive;
  final List<_TreeSeason> seasons;
  const _TreeSeries(
      {required this.key,
      required this.title,
      required this.isArchive,
      required this.seasons});

  List<String> get allPaths =>
      [for (final s in seasons) ...s.allPaths];
}

class _TreeSeason {
  final int number;
  final String displayName;
  final List<_TreeEpisode> episodes;
  const _TreeSeason(
      {required this.number,
      required this.displayName,
      required this.episodes});

  List<String> get allPaths => [for (final e in episodes) e.path];
}

class _TreeEpisode {
  final int number;
  final String title;
  final String path;
  const _TreeEpisode(
      {required this.number, required this.title, required this.path});
}

class _TreeMovie {
  final String key;
  final String title;
  final String path;
  final bool isArchive;
  const _TreeMovie(
      {required this.key,
      required this.title,
      required this.path,
      required this.isArchive});
}

/// Stateful so we can live-remove nodes after a reset. The tree
/// represents "what has cache on disk", not the library; removing a
/// node signals "this path no longer has cache" and hides it until a
/// rebuild re-creates it.
class _ResetTreeExpansion extends ConsumerStatefulWidget {
  const _ResetTreeExpansion();

  @override
  ConsumerState<_ResetTreeExpansion> createState() =>
      _ResetTreeExpansionState();
}

class _ResetTreeExpansionState extends ConsumerState<_ResetTreeExpansion> {
  /// Paths the user has just reset in this session. Filtered out of
  /// the tree so the action feels immediate. Cleared on library
  /// refresh (which would rebuild cache anyway).
  final Set<String> _hidden = {};

  void _onReset(Iterable<String> paths) {
    setState(() => _hidden.addAll(paths));
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(mediaLibraryProvider);
    final history = ref.watch(mediaHistoryProvider);

    final currentIds = {for (final i in library.items) i.id};

    // The reset tree is a VIEW ON THE CACHE. A path only appears if
    // thumbnails for it actually exist on disk — otherwise offering
    // "reset this" on an empty cache is confusing and makes the
    // settings page diverge from the real state (user's previous
    // complaint: "Serie steht im Tree obwohl Cache leer ist").
    //
    // [pathsWithCache] is maintained by the provider: rebuilt from
    // disk after every scan, pruned after every reset, appended
    // after every successful generation.
    final cachedPaths = library.pathsWithCache;

    // Build uniform tree entries.
    final currentMovies = <_TreeMovie>[];
    final currentSeries = <_TreeSeries>[];
    for (final i in library.items) {
      if (i.type == MediaType.movie && i.movieFilePath != null) {
        currentMovies.add(_TreeMovie(
          key: i.id,
          title: i.title,
          path: i.movieFilePath!,
          isArchive: false,
        ));
      } else if (i.type == MediaType.series) {
        currentSeries.add(_TreeSeries(
          key: i.id,
          title: i.title,
          isArchive: false,
          seasons: [
            for (final s in i.seasons)
              _TreeSeason(
                number: s.number,
                displayName: s.displayName,
                episodes: [
                  for (final ep in s.episodes)
                    _TreeEpisode(
                      number: ep.episodeNumber,
                      title: ep.title,
                      path: ep.filePath,
                    ),
                ],
              ),
          ],
        ));
      }
    }

    final archiveMovies = <_TreeMovie>[];
    final archiveSeries = <_TreeSeries>[];
    for (final m in history) {
      if (currentIds.contains(m.mediaId)) continue;
      final snap = m.snapshot;
      if (m.typeIndex == MediaType.movie.index) {
        final movie = snap['movie'] as Map?;
        if (movie != null && movie['path'] is String) {
          archiveMovies.add(_TreeMovie(
            key: m.mediaId,
            title: m.title,
            path: movie['path'] as String,
            isArchive: true,
          ));
        }
      } else if (m.typeIndex == MediaType.series.index) {
        final seasonsRaw = (snap['seasons'] as List?)?.cast<Map>() ?? const [];
        final seasons = <_TreeSeason>[];
        for (final s in seasonsRaw) {
          final eps = (s['episodes'] as List?)?.cast<Map>() ?? const [];
          seasons.add(_TreeSeason(
            number: (s['num'] as num?)?.toInt() ?? 0,
            displayName: 'Staffel ${s['num'] ?? '?'}',
            episodes: [
              for (final e in eps)
                _TreeEpisode(
                  number: (e['num'] as num?)?.toInt() ?? 0,
                  title: (e['name'] as String?) ?? '—',
                  path: (e['path'] as String?) ?? '',
                ),
            ],
          ));
        }
        if (seasons.isNotEmpty) {
          archiveSeries.add(_TreeSeries(
            key: m.mediaId,
            title: m.title,
            isArchive: true,
            seasons: seasons,
          ));
        }
      }
    }

    // A path is visible if it's not hidden by a just-performed reset
    // AND it actually has a cache on disk. Both conditions matter:
    //  - `_hidden` gives instant feedback on the current session
    //    (without waiting for the provider's set to update).
    //  - `cachedPaths` is the persistent source of truth after scans
    //    and app restarts.
    bool visible(String path) =>
        !_hidden.contains(path) && cachedPaths.contains(path);
    List<_TreeSeason> filterSeasons(List<_TreeSeason> ss) {
      final out = <_TreeSeason>[];
      for (final s in ss) {
        final eps = s.episodes.where((e) => visible(e.path)).toList();
        if (eps.isNotEmpty) {
          out.add(_TreeSeason(
            number: s.number,
            displayName: s.displayName,
            episodes: eps,
          ));
        }
      }
      return out;
    }

    final visMovies = currentMovies.where((m) => visible(m.path)).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final visSeries = [
      for (final s in currentSeries)
        if (filterSeasons(s.seasons).isNotEmpty)
          _TreeSeries(
            key: s.key,
            title: s.title,
            isArchive: s.isArchive,
            seasons: filterSeasons(s.seasons),
          ),
    ]..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final visArchiveMovies =
        archiveMovies.where((m) => visible(m.path)).toList()
          ..sort((a, b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final visArchiveSeries = [
      for (final s in archiveSeries)
        if (filterSeasons(s.seasons).isNotEmpty)
          _TreeSeries(
            key: s.key,
            title: s.title,
            isArchive: s.isArchive,
            seasons: filterSeasons(s.seasons),
          ),
    ]..sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final anyCurrent = visMovies.isNotEmpty || visSeries.isNotEmpty;
    final anyArchive =
        visArchiveMovies.isNotEmpty || visArchiveSeries.isNotEmpty;

    return _Card(
      child: ExpansionTile(
        iconColor: AppTheme.textSecondary,
        collapsedIconColor: AppTheme.textSecondary,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.only(bottom: 4),
        leading: _leadingIcon(Icons.restart_alt_rounded),
        title: const Text(
          'Cache einzeln zurücksetzen',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: const Text(
          'Vorschaubilder gezielt pro Film, Serie, Staffel oder Episode löschen',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
        ),
        children: [
          if (!anyCurrent && !anyArchive)
            const _EmptyHint(
                'Bibliothek ist leer und im Archiv steht auch nichts'),
          if (anyCurrent) const _Subheader(title: 'Aktuelle Medien'),
          if (visMovies.isNotEmpty) ...[
            const _MiniSubheader(title: 'Filme'),
            ..._withDividers([
              for (final m in visMovies)
                _MovieResetRow(movie: m, onReset: _onReset),
            ]),
          ],
          if (visSeries.isNotEmpty) ...[
            const _MiniSubheader(title: 'Serien'),
            ..._withDividers([
              for (final s in visSeries)
                _SeriesResetNode(series: s, onReset: _onReset),
            ]),
          ],
          if (anyArchive) ...[
            const SizedBox(height: 8),
            const _Subheader(title: 'Archiv'),
          ],
          if (visArchiveMovies.isNotEmpty) ...[
            const _MiniSubheader(title: 'Filme'),
            ..._withDividers([
              for (final m in visArchiveMovies)
                _MovieResetRow(movie: m, onReset: _onReset),
            ]),
          ],
          if (visArchiveSeries.isNotEmpty) ...[
            const _MiniSubheader(title: 'Serien'),
            ..._withDividers([
              for (final s in visArchiveSeries)
                _SeriesResetNode(series: s, onReset: _onReset),
            ]),
          ],
        ],
      ),
    );
  }
}

class _MovieResetRow extends StatelessWidget {
  final _TreeMovie movie;
  final void Function(Iterable<String>) onReset;
  const _MovieResetRow({required this.movie, required this.onReset});

  @override
  Widget build(BuildContext context) {
    return _HoverRow(
      child: Padding(
        padding: const EdgeInsets.only(left: 24, right: 8, top: 4, bottom: 4),
        child: Row(
          children: [
            Icon(
              movie.isArchive
                  ? Icons.movie_filter_outlined
                  : Icons.movie_rounded,
              size: 18,
              color: AppTheme.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                movie.title,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _ResetIconButton(
              tooltip: 'Cache zurücksetzen',
              paths: [movie.path],
              onReset: onReset,
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesResetNode extends StatelessWidget {
  final _TreeSeries series;
  final void Function(Iterable<String>) onReset;
  const _SeriesResetNode({required this.series, required this.onReset});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        iconColor: AppTheme.textSecondary,
        collapsedIconColor: AppTheme.textSecondary,
        tilePadding: const EdgeInsets.only(left: 24, right: 8),
        childrenPadding: EdgeInsets.zero,
        leading: Icon(
          series.isArchive ? Icons.tv_off_rounded : Icons.tv_rounded,
          size: 18,
          color: AppTheme.textMuted,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                series.title,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _ResetIconButton(
              tooltip: 'Cache dieser Serie komplett zurücksetzen',
              paths: series.allPaths,
              onReset: onReset,
            ),
          ],
        ),
        // Per-series inner scroll — caps how tall ONE series's expanded
        // content can get so a giant show with 12 seasons doesn't push
        // the rest of the tree off-screen. The cap is generous so a
        // "normal" sized series (e.g. 4 seasons x 10 episodes) renders
        // fully without the scrollbar kicking in; only really big
        // shows actually need to scroll.
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 620),
            child: Scrollbar(
              thumbVisibility: series.seasons.length > 6,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(right: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final s in series.seasons)
                      _SeasonResetNode(season: s, onReset: onReset),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonResetNode extends StatelessWidget {
  final _TreeSeason season;
  final void Function(Iterable<String>) onReset;
  const _SeasonResetNode({required this.season, required this.onReset});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        iconColor: AppTheme.textSecondary,
        collapsedIconColor: AppTheme.textSecondary,
        tilePadding: const EdgeInsets.only(left: 44, right: 8),
        childrenPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_open_rounded,
            size: 16, color: AppTheme.textMuted),
        title: Row(
          children: [
            Expanded(
              child: Text(
                season.displayName,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13),
              ),
            ),
            _ResetIconButton(
              tooltip: 'Cache dieser Staffel zurücksetzen',
              paths: season.allPaths,
              onReset: onReset,
            ),
          ],
        ),
        children: [
          for (final ep in season.episodes)
            _HoverRow(
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 64, right: 8, top: 2, bottom: 2),
                child: Row(
                  children: [
                    const Icon(Icons.play_circle_outline,
                        size: 14, color: AppTheme.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'E${ep.number.toString().padLeft(2, '0')} · ${ep.title}',
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _ResetIconButton(
                      tooltip: 'Cache dieser Episode zurücksetzen',
                      paths: [ep.path],
                      onReset: onReset,
                      compact: true,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResetIconButton extends ConsumerWidget {
  final String tooltip;
  final List<String> paths;
  final void Function(Iterable<String>) onReset;
  final bool compact;
  const _ResetIconButton({
    required this.tooltip,
    required this.paths,
    required this.onReset,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (paths.isEmpty) return const SizedBox.shrink();
    return IconButton(
      tooltip: tooltip,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      iconSize: compact ? 16 : 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: () async {
        final ok = await _confirm(context, paths.length);
        if (ok != true) return;
        // Single-item reset: do NOT trigger refresh (would regen
        // immediately and defeat the point). The node is removed
        // from the tree locally via onReset so the user sees the
        // action took effect.
        await ref.read(mediaLibraryProvider.notifier).resetCacheForPaths(
              paths,
              triggerRefresh: false,
            );
        onReset(paths);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cache für ${paths.length} Datei(en) gelöscht',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      icon: const Icon(Icons.delete_outline_rounded,
          color: AppTheme.textMuted),
    );
  }

  Future<bool?> _confirm(BuildContext context, int count) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cache zurücksetzen?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Vorschaubilder für $count Datei(en) werden gelöscht.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Zurücksetzen',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Helpers ─────────────────────────

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

Widget _leadingIcon(IconData icon) {
  return Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppTheme.surfaceLight,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon, color: AppTheme.textPrimary, size: 22),
  );
}

List<Widget> _withDividers(List<Widget> rows) {
  if (rows.length < 2) return rows;
  final out = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    out.add(rows[i]);
    if (i < rows.length - 1) {
      out.add(const Divider(
        height: 1,
        thickness: 1,
        indent: 16,
        endIndent: 16,
        color: Color(0x14FFFFFF),
      ));
    }
  }
  return out;
}

class _HoverRow extends StatefulWidget {
  final Widget child;
  const _HoverRow({required this.child});

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _hover
            ? AppTheme.surfaceLight.withValues(alpha: 0.35)
            : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: AppTheme.surface,
        child: child,
      ),
    );
  }
}

class _Subheader extends StatelessWidget {
  final String title;
  const _Subheader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _MiniSubheader extends StatelessWidget {
  final String title;
  const _MiniSubheader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 16, 2),
      child: Text(
        title,
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// Two side-by-side bulk actions at the top of the keep-flag section.
/// Replaces the old global toggle. Each button is a one-shot — the
/// system has no persistent "auto-keep" mode any more.
class _BulkActionsRow extends ConsumerWidget {
  const _BulkActionsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.accent,
                side: const BorderSide(color: AppTheme.accent),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.flag_rounded, size: 18),
              label: const Text(
                'Alle flaggen',
                style: TextStyle(fontSize: 13),
              ),
              onPressed: () => _confirmFlagAll(context, ref),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                side: BorderSide(color: AppTheme.textMuted.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.cleaning_services_rounded, size: 18),
              label: const Text(
                'Flags entfernen & Archiv säubern',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
              onPressed: () => _confirmUnflagAndClean(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmFlagAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Alle flaggen?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Alle bekannten Medien (aktuell + Archiv) werden für Behaltung '
          'markiert. Ihre Caches überleben damit jede Aktualisierung, '
          'bis du die Flag wieder einzeln entfernst.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Alle flaggen',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(mediaHistoryProvider.notifier).setKeepCacheForAll(true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Alle Einträge geflaggt'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _confirmUnflagAndClean(
      BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Flags entfernen & Archiv säubern?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Alle Flags werden entfernt. Anschließend werden ALLE '
          'archivierten Einträge (= Medien, die nicht mehr im '
          'Bibliotheks-Ordner liegen) samt Cache gelöscht.\n\n'
          'Aktuelle Medien bleiben unverändert — ihre Caches werden '
          'erst entfernt, wenn die Dateien tatsächlich verschwinden.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Durchführen',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(mediaHistoryProvider.notifier).setKeepCacheForAll(false);
    final removed =
        await ref.read(mediaLibraryProvider.notifier).cleanUnflaggedArchive();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed == 0
                ? 'Alle Flags entfernt (Archiv war leer)'
                : 'Alle Flags entfernt, $removed archivierte Einträge gelöscht',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 13,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}
