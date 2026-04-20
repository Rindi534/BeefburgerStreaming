import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/media_item.dart';
import '../models/media_metadata.dart';

/// Structural difference detected between a previously-stored snapshot
/// and the current scan of a media item. Surfaced to the user so they
/// can decide whether the existing thumbnail cache is still valid.
class MediaChange {
  /// Short human-readable line shown in the change dialog, e.g.
  /// "Staffel 2 · Episode 3 — Dateigröße geändert".
  final String description;
  /// Subset of the video paths affected by this specific change. A
  /// user-initiated "Neu erstellen" clears the thumbnail folder for
  /// each of these paths.
  final List<String> affectedPaths;
  /// Nature of the change — used to pick icons + colour in the UI.
  final MediaChangeKind kind;

  const MediaChange({
    required this.description,
    required this.affectedPaths,
    required this.kind,
  });
}

enum MediaChangeKind {
  /// New file/season/episode that wasn't in the previous snapshot.
  /// Not destructive — new cache is generated automatically.
  added,
  /// File is gone. Cache for the old path is stale and will be
  /// cleaned up on orphan-prune unless the user has flagged the item
  /// for keeping.
  removed,
  /// Same path, but the file's size differs → very likely a
  /// re-encode / different release. Old thumbnails don't match the
  /// new content.
  modified,
}

/// Bundle of detected changes per media item, emitted once per scan
/// so the UI can show a single summary dialog rather than interrupting
/// the scan with one alert per episode.
class MediaChangeBundle {
  final String mediaId;
  final String title;
  final List<MediaChange> changes;

  const MediaChangeBundle({
    required this.mediaId,
    required this.title,
    required this.changes,
  });

  bool get hasModificationsOrRemovals => changes
      .any((c) => c.kind != MediaChangeKind.added);
}

class MediaHistoryNotifier extends StateNotifier<List<MediaMetadata>> {
  final Box<MediaMetadata> _box;

  MediaHistoryNotifier(this._box) : super(_box.values.toList()) {
    // Watch box changes so UI listening to the provider rebuilds
    // immediately after an upsert (e.g. scan finishes → keep-list
    // refreshes in settings).
    _box.watch().listen((_) {
      state = _box.values.toList();
    });
  }

  MediaMetadata? get(String mediaId) => _box.get(mediaId);

  bool isFlagged(String mediaId) => _box.get(mediaId)?.keepCache == true;

  /// Every video path across all history entries that have keepCache=true.
  /// Used to spare those paths from orphan cleanup.
  Set<String> get keptVideoPaths {
    final out = <String>{};
    for (final e in _box.values) {
      if (e.keepCache) out.addAll(e.allVideoPaths);
    }
    return out;
  }

  /// Every video path across ALL history entries (including not-flagged
  /// ones). Used when the global "Cache für entfernte Medien behalten"
  /// setting is on — everything we've ever seen survives cleanup.
  Set<String> get allHistoricVideoPaths {
    final out = <String>{};
    for (final e in _box.values) {
      out.addAll(e.allVideoPaths);
    }
    return out;
  }

  List<MediaMetadata> get flaggedItems =>
      _box.values.where((e) => e.keepCache).toList()
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  /// Items currently absent from [currentIds] — the "Archiv" view in
  /// settings. These are entries the user may want to unflag or drop.
  List<MediaMetadata> historicItemsMissingFrom(Set<String> currentIds) {
    return _box.values
        .where((e) => !currentIds.contains(e.mediaId))
        .toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  /// Write the current scan into history. Existing records keep their
  /// [firstSeen] + [keepCache]. Returns a list of per-item change
  /// bundles that were detected against the PREVIOUS snapshot (empty
  /// if nothing tracked yet or no changes).
  ///
  /// [defaultKeepForNew] sets the initial keepCache flag on brand-new
  /// items (first time this media is seen). Typically passed as the
  /// current global "Cache für entfernte Medien behalten" setting so
  /// enabling that toggle makes every fresh scan's additions
  /// protected by default.
  Future<List<MediaChangeBundle>> upsertFromLibrary(
    List<MediaItem> items, {
    bool defaultKeepForNew = false,
  }) async {
    final now = DateTime.now();
    final changes = <MediaChangeBundle>[];

    for (final item in items) {
      final existing = _box.get(item.id);
      final newSnapshot = _buildSnapshot(item);
      final newJson = jsonEncode(newSnapshot);

      if (existing != null) {
        // Only report changes if the existing record actually had a
        // snapshot AND the thumbnail cache may still reference old
        // paths — otherwise there's nothing for the user to decide.
        final detected = _detectChanges(
          existingSnapshot: existing.snapshot,
          newSnapshot: newSnapshot,
        );
        if (detected.isNotEmpty) {
          changes.add(MediaChangeBundle(
            mediaId: item.id,
            title: item.title,
            changes: detected,
          ));
        }
      }

      final merged = existing?.copyWith(
            title: item.title,
            typeIndex: item.type.index,
            lastSeen: now,
            snapshotJson: newJson,
          ) ??
          MediaMetadata(
            mediaId: item.id,
            title: item.title,
            typeIndex: item.type.index,
            keepCache: defaultKeepForNew,
            firstSeen: now,
            lastSeen: now,
            snapshotJson: newJson,
          );
      await _box.put(item.id, merged);
    }
    return changes;
  }

  Future<void> setKeepCache(String mediaId, bool keep) async {
    final existing = _box.get(mediaId);
    if (existing == null) return;
    await _box.put(mediaId, existing.copyWith(keepCache: keep));
  }

  /// Flip the keep-flag on every stored entry in one shot. Used when
  /// the user turns on the global "Cache für entfernte Medien
  /// behalten" toggle — it's a convenience that says "protect
  /// everything I currently know about". Per-item flags take over
  /// from there; the global toggle itself doesn't participate in the
  /// cleanup rule any more.
  Future<void> setKeepCacheForAll(bool keep) async {
    for (final entry in _box.values.toList()) {
      if (entry.keepCache != keep) {
        await _box.put(entry.mediaId, entry.copyWith(keepCache: keep));
      }
    }
  }

  /// Drop a history entry entirely (e.g. user taps the trash icon on
  /// an archived item they don't care about any more).
  Future<void> removeEntry(String mediaId) async {
    await _box.delete(mediaId);
  }

  /// Builds the JSON-serialisable snapshot of a MediaItem. Keep the
  /// field names short to keep the Hive value compact.
  Map<String, dynamic> _buildSnapshot(MediaItem item) {
    final paths = <String>[];
    Map<String, dynamic>? movie;
    List<Map<String, dynamic>> seasons = const [];

    if (item.type == MediaType.movie && item.movieFilePath != null) {
      final f = File(item.movieFilePath!);
      final size = _safeLength(f);
      movie = {
        'name': _filename(item.movieFilePath!),
        'size': size,
        'path': item.movieFilePath!,
      };
      paths.add(item.movieFilePath!);
    } else if (item.type == MediaType.series) {
      seasons = [];
      for (final s in item.seasons) {
        final eps = <Map<String, dynamic>>[];
        for (final ep in s.episodes) {
          final size = _safeLength(File(ep.filePath));
          eps.add({
            'num': ep.episodeNumber,
            'name': _filename(ep.filePath),
            'size': size,
            'path': ep.filePath,
          });
          paths.add(ep.filePath);
        }
        seasons.add({'num': s.number, 'episodes': eps});
      }
    }

    return {
      'paths': paths,
      if (movie != null) 'movie': movie,
      if (item.type == MediaType.series) 'seasons': seasons,
    };
  }

  List<MediaChange> _detectChanges({
    required Map<String, dynamic> existingSnapshot,
    required Map<String, dynamic> newSnapshot,
  }) {
    final changes = <MediaChange>[];

    // Movie comparison — only name + size. Same name & size → treat
    // as identical (don't probe duration — expensive and rarely
    // differs without a size difference).
    final oldMovie = existingSnapshot['movie'] as Map?;
    final newMovie = newSnapshot['movie'] as Map?;
    if (oldMovie != null && newMovie != null) {
      if (oldMovie['name'] != newMovie['name']) {
        changes.add(MediaChange(
          description:
              'Dateiname geändert: ${oldMovie['name']} → ${newMovie['name']}',
          affectedPaths: [newMovie['path'] as String],
          kind: MediaChangeKind.modified,
        ));
      } else if (_numEquals(oldMovie['size'], newMovie['size']) == false) {
        changes.add(MediaChange(
          description:
              'Dateigröße geändert${_sizeDelta(oldMovie['size'], newMovie['size'])}',
          affectedPaths: [newMovie['path'] as String],
          kind: MediaChangeKind.modified,
        ));
      }
    }

    // Series comparison — season-by-season, episode-by-episode.
    final oldSeasons =
        (existingSnapshot['seasons'] as List?)?.cast<Map>() ?? const [];
    final newSeasons =
        (newSnapshot['seasons'] as List?)?.cast<Map>() ?? const [];
    if (oldSeasons.isNotEmpty || newSeasons.isNotEmpty) {
      final oldByNum = {for (final s in oldSeasons) s['num'] as int: s};
      final newByNum = {for (final s in newSeasons) s['num'] as int: s};

      // Added / removed seasons first.
      for (final n in newByNum.keys.toSet().difference(oldByNum.keys.toSet())) {
        changes.add(MediaChange(
          description: 'Staffel $n neu hinzugefügt',
          affectedPaths: _pathsInSeason(newByNum[n]!),
          kind: MediaChangeKind.added,
        ));
      }
      for (final n in oldByNum.keys.toSet().difference(newByNum.keys.toSet())) {
        changes.add(MediaChange(
          description: 'Staffel $n entfernt',
          affectedPaths: _pathsInSeason(oldByNum[n]!),
          kind: MediaChangeKind.removed,
        ));
      }

      // Per-episode diff in seasons present on both sides.
      for (final n in oldByNum.keys.toSet().intersection(newByNum.keys.toSet())) {
        final oldEps = ((oldByNum[n]!['episodes']) as List).cast<Map>();
        final newEps = ((newByNum[n]!['episodes']) as List).cast<Map>();
        final oldEpByNum = {for (final e in oldEps) e['num'] as int: e};
        final newEpByNum = {for (final e in newEps) e['num'] as int: e};

        for (final ne in newEpByNum.keys.toSet().difference(oldEpByNum.keys.toSet())) {
          changes.add(MediaChange(
            description: 'Staffel $n · Episode $ne neu',
            affectedPaths: [newEpByNum[ne]!['path'] as String],
            kind: MediaChangeKind.added,
          ));
        }
        for (final ne in oldEpByNum.keys.toSet().difference(newEpByNum.keys.toSet())) {
          changes.add(MediaChange(
            description: 'Staffel $n · Episode $ne entfernt',
            affectedPaths: [oldEpByNum[ne]!['path'] as String],
            kind: MediaChangeKind.removed,
          ));
        }
        for (final ne in oldEpByNum.keys.toSet().intersection(newEpByNum.keys.toSet())) {
          final o = oldEpByNum[ne]!;
          final nw = newEpByNum[ne]!;
          if (o['name'] != nw['name']) {
            changes.add(MediaChange(
              description:
                  'Staffel $n · Episode $ne · Dateiname geändert',
              affectedPaths: [nw['path'] as String],
              kind: MediaChangeKind.modified,
            ));
          } else if (_numEquals(o['size'], nw['size']) == false) {
            changes.add(MediaChange(
              description:
                  'Staffel $n · Episode $ne · Dateigröße geändert${_sizeDelta(o['size'], nw['size'])}',
              affectedPaths: [nw['path'] as String],
              kind: MediaChangeKind.modified,
            ));
          }
        }
      }
    }
    return changes;
  }

  List<String> _pathsInSeason(Map season) {
    final eps = (season['episodes'] as List).cast<Map>();
    return [for (final e in eps) e['path'] as String];
  }

  int? _safeLength(File f) {
    try {
      return f.existsSync() ? f.lengthSync() : null;
    } catch (_) {
      return null;
    }
  }

  String _filename(String path) {
    final idx = path.replaceAll('\\', '/').lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  /// Treats null/missing sizes as equal to each other so we don't
  /// falsely flag items where we couldn't read the size on either side
  /// (e.g. external drive hiccup during the old scan).
  bool _numEquals(dynamic a, dynamic b) {
    if (a == null || b == null) return true;
    return a == b;
  }

  String _fmtBytes(dynamic v) {
    if (v == null) return '—';
    final n = v is int ? v : int.tryParse('$v') ?? 0;
    if (n < 1024) return '$n B';
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (n < mb) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < gb) return '${(n / mb).toStringAsFixed(1)} MB';
    return '${(n / gb).toStringAsFixed(2)} GB';
  }

  /// Returns " (A → B)" only when the rounded display values differ.
  /// If both sides round to the same string (e.g. 1.32 GB → 1.32 GB
  /// for two files that differ by a few MB), we suppress the delta
  /// because it looks broken — the user just sees an identical string
  /// on both sides of an arrow. Leading space included by design so
  /// the caller can do `'... geändert${_sizeDelta(a, b)}'` and get
  /// clean output in both cases.
  String _sizeDelta(dynamic oldV, dynamic newV) {
    final a = _fmtBytes(oldV);
    final b = _fmtBytes(newV);
    if (a == b) return '';
    return ' ($a → $b)';
  }
}

final mediaHistoryProvider =
    StateNotifierProvider<MediaHistoryNotifier, List<MediaMetadata>>((ref) {
  final box = Hive.box<MediaMetadata>('media_history');
  return MediaHistoryNotifier(box);
});
