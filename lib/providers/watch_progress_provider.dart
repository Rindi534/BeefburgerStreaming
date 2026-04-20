import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/watch_progress.dart';

class WatchProgressNotifier extends StateNotifier<List<WatchProgress>> {
  final Box<WatchProgress> _box;

  WatchProgressNotifier(this._box) : super(_box.values.toList()) {
    _sortByLastWatched();
  }

  void _sortByLastWatched() {
    state = List.from(state)
      ..sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
  }

  Future<void> updateProgress({
    required String mediaId,
    required String filePath,
    required Duration position,
    required Duration totalDuration,
    String? mediaTitle,
    String? episodeTitle,
    String? coverImagePath,
  }) async {
    final progress = WatchProgress(
      mediaId: mediaId,
      filePath: filePath,
      position: position,
      totalDuration: totalDuration,
      lastWatched: DateTime.now(),
      mediaTitle: mediaTitle,
      episodeTitle: episodeTitle,
      coverImagePath: coverImagePath,
    );

    await _box.put(filePath, progress);
    state = _box.values.toList();
    _sortByLastWatched();
  }

  WatchProgress? getProgress(String filePath) {
    return _box.get(filePath);
  }

  List<WatchProgress> get continueWatching {
    final eligible = state
        .where((p) => (p.hasStarted || p.position == Duration.zero) && !p.isCompleted)
        .toList();
    // Deduplicate: keep only the most recent entry per mediaId
    final Map<String, WatchProgress> latest = {};
    for (final p in eligible) {
      final existing = latest[p.mediaId];
      if (existing == null || p.lastWatched.isAfter(existing.lastWatched)) {
        latest[p.mediaId] = p;
      }
    }
    final result = latest.values.toList()
      ..sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
    return result;
  }

  Future<void> clearProgressByMediaId(
    String mediaId, {
    List<String>? episodeFilePaths,
  }) async {
    final filePathSet = episodeFilePaths?.toSet() ?? <String>{};
    final keysToRemove = <dynamic>[];
    for (final entry in _box.toMap().entries) {
      // Match by mediaId OR by filePath (for entries with inconsistent mediaId)
      if (entry.value.mediaId == mediaId ||
          filePathSet.contains(entry.key) ||
          filePathSet.contains(entry.value.filePath)) {
        keysToRemove.add(entry.key);
      }
    }
    for (final key in keysToRemove) {
      await _box.delete(key);
    }
    state = _box.values.toList();
    _sortByLastWatched();
  }

  Future<void> clearProgress(String filePath) async {
    await _box.delete(filePath);
    state = _box.values.toList();
    _sortByLastWatched();
  }

  /// Removes all progress entries whose filePath is not in [validFilePaths].
  /// Used after a library scan to drop entries for videos that have been
  /// deleted/moved, so they don't linger as ghost tiles under "Weiterschauen".
  /// Returns the number of entries removed.
  Future<int> pruneOrphaned(Set<String> validFilePaths) async {
    // Safety: an empty set likely means the scan itself failed or returned
    // nothing transiently — don't wipe the entire watch history on that.
    if (validFilePaths.isEmpty) return 0;
    final keysToRemove = <dynamic>[];
    for (final entry in _box.toMap().entries) {
      if (!validFilePaths.contains(entry.value.filePath)) {
        keysToRemove.add(entry.key);
      }
    }
    if (keysToRemove.isEmpty) return 0;
    for (final key in keysToRemove) {
      await _box.delete(key);
    }
    state = _box.values.toList();
    _sortByLastWatched();
    return keysToRemove.length;
  }

  Future<void> clearAll() async {
    await _box.clear();
    state = [];
  }
}

final watchProgressProvider =
    StateNotifierProvider<WatchProgressNotifier, List<WatchProgress>>((ref) {
  final box = Hive.box<WatchProgress>('watch_progress');
  return WatchProgressNotifier(box);
});

final continueWatchingProvider = Provider<List<WatchProgress>>((ref) {
  ref.watch(watchProgressProvider);
  return ref.read(watchProgressProvider.notifier).continueWatching;
});
