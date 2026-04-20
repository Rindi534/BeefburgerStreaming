import 'dart:convert';
import 'package:hive/hive.dart';

part 'media_metadata.g.dart';

/// Persistent record of a media item the app has ever seen in the library,
/// regardless of whether it is currently present on disk.
///
/// Used for three things:
///  1. "Keep cache for removed media" — per-item flag [keepCache] plus the
///     global [keepCacheForRemovedMedia] setting decide whether
///     [ThumbnailService.cleanupOrphaned] should spare a no-longer-scanned
///     item's thumbnail folders.
///  2. Reuse detection — when a previously-known folder reappears, we
///     compare its structure against [snapshotJson] to decide whether the
///     cached thumbnails are still valid or need regeneration.
///  3. The "Archiv" list in Settings so users can manage flags for media
///     that has since been removed from the folder.
@HiveType(typeId: 1)
class MediaMetadata extends HiveObject {
  @HiveField(0)
  final String mediaId; // = MediaItem.path (stable within one library root)
  @HiveField(1)
  final String title;
  /// 0 = movie, 1 = series. Stored as int so adding a new MediaType
  /// variant later doesn't break existing Hive records.
  @HiveField(2)
  final int typeIndex;
  @HiveField(3)
  final bool keepCache;
  @HiveField(4)
  final DateTime firstSeen;
  @HiveField(5)
  final DateTime lastSeen;
  /// JSON-encoded structural snapshot of the item, used for change
  /// detection when the folder reappears. Stored as a string (rather
  /// than nested Hive types) so we can evolve the schema without
  /// writing migration code for every small tweak.
  ///
  /// Shape:
  /// {
  ///   "paths": ["...", "..."],   // every video file path belonging to the item
  ///   "movie": {"name": "...", "size": 1234} | null,
  ///   "seasons": [
  ///      {"num": 1, "episodes": [{"num":1,"name":"...","size":1234,"path":"..."}, ...]}
  ///   ]
  /// }
  @HiveField(6)
  final String snapshotJson;

  MediaMetadata({
    required this.mediaId,
    required this.title,
    required this.typeIndex,
    required this.keepCache,
    required this.firstSeen,
    required this.lastSeen,
    required this.snapshotJson,
  });

  MediaMetadata copyWith({
    String? title,
    int? typeIndex,
    bool? keepCache,
    DateTime? lastSeen,
    String? snapshotJson,
  }) {
    return MediaMetadata(
      mediaId: mediaId,
      title: title ?? this.title,
      typeIndex: typeIndex ?? this.typeIndex,
      keepCache: keepCache ?? this.keepCache,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      snapshotJson: snapshotJson ?? this.snapshotJson,
    );
  }

  /// Returns every video file path recorded in the snapshot. Used both
  /// for sparing those dirs from orphan cleanup and for locating the
  /// thumbnail folders that a per-item reset needs to clear.
  List<String> get allVideoPaths {
    try {
      final decoded = jsonDecode(snapshotJson) as Map<String, dynamic>;
      final paths = (decoded['paths'] as List?)?.cast<String>();
      return paths ?? const [];
    } catch (_) {
      // Corrupt snapshot — treat as "no known paths" rather than crashing
      // the whole cleanup pass.
      return const [];
    }
  }

  /// Parsed snapshot. Returns empty map on any decode error so callers
  /// can treat the item as "unknown structure" and surface it via the
  /// change-detection dialog rather than crashing.
  Map<String, dynamic> get snapshot {
    try {
      return jsonDecode(snapshotJson) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }
}
