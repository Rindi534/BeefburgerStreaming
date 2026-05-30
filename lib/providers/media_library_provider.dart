import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/media_item.dart';
import '../services/media_scanner.dart';
import '../services/thumbnail_service.dart';
import 'media_history_provider.dart';
import 'settings_provider.dart';
import 'watch_progress_provider.dart';

/// Hive key in the `settings` box used to persist
/// [MediaLibraryState.manuallyClearedPaths] across app restarts.
/// Persistence is essential because the user can hit reset, close the
/// app, reopen it, and the next scan would otherwise silently
/// regenerate — defeating the whole point of the manual reset.
const _kManuallyClearedKey = 'manuallyClearedPaths';

class MediaLibraryState {
  final List<MediaItem> items;
  final bool isLoading;
  final String? error;
  // Thumbnail generation progress
  final bool isGeneratingThumbnails;
  final int thumbnailsCurrent;
  final int thumbnailsTotal;
  final String? currentThumbnailLabel;
  final bool ffmpegMissing;
  // Non-fatal warning shown as a snackbar when thumbnail generation has to
  // abort (disk full, unwritable cache). Distinct from [error] which is the
  // fatal "scan could not run at all" state.
  final String? thumbnailWarning;
  /// Set after a scan has detected structural changes (added/removed/
  /// modified episodes or files) in at least one previously-known
  /// media item. The home screen watches this and shows a one-shot
  /// banner → dialog so the user can decide per-bundle whether to
  /// reset the affected thumbnail cache or keep it.
  final List<MediaChangeBundle> pendingChanges;

  /// Paths the user has manually reset via the per-item tree in
  /// settings. Persisted in the Hive settings box so a reset survives
  /// app restart — otherwise closing the app between reset and the
  /// next scan would silently lose the "don't auto-regen" decision.
  /// Cleared once a scan has surfaced them through the change dialog.
  final Set<String> manuallyClearedPaths;

  /// Set of video paths whose thumbnail cache actually exists on disk
  /// RIGHT NOW. Recomputed after every scan and after every cache
  /// mutation (reset, generation). The per-item reset tree filters by
  /// this so the tree reflects the disk state — a path whose cache
  /// folder is gone won't appear as "resettable", no matter whether
  /// it's in library or history.
  final Set<String> pathsWithCache;

  const MediaLibraryState({
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.isGeneratingThumbnails = false,
    this.thumbnailsCurrent = 0,
    this.thumbnailsTotal = 0,
    this.currentThumbnailLabel,
    this.ffmpegMissing = false,
    this.thumbnailWarning,
    this.pendingChanges = const [],
    this.manuallyClearedPaths = const {},
    this.pathsWithCache = const {},
  });

  MediaLibraryState copyWith({
    List<MediaItem>? items,
    bool? isLoading,
    String? error,
    bool? isGeneratingThumbnails,
    int? thumbnailsCurrent,
    int? thumbnailsTotal,
    String? currentThumbnailLabel,
    bool? ffmpegMissing,
    String? thumbnailWarning,
    bool clearThumbnailWarning = false,
    List<MediaChangeBundle>? pendingChanges,
    Set<String>? manuallyClearedPaths,
    Set<String>? pathsWithCache,
  }) {
    return MediaLibraryState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isGeneratingThumbnails:
          isGeneratingThumbnails ?? this.isGeneratingThumbnails,
      thumbnailsCurrent: thumbnailsCurrent ?? this.thumbnailsCurrent,
      thumbnailsTotal: thumbnailsTotal ?? this.thumbnailsTotal,
      currentThumbnailLabel:
          currentThumbnailLabel ?? this.currentThumbnailLabel,
      ffmpegMissing: ffmpegMissing ?? this.ffmpegMissing,
      thumbnailWarning: clearThumbnailWarning
          ? null
          : (thumbnailWarning ?? this.thumbnailWarning),
      pendingChanges: pendingChanges ?? this.pendingChanges,
      manuallyClearedPaths:
          manuallyClearedPaths ?? this.manuallyClearedPaths,
      pathsWithCache: pathsWithCache ?? this.pathsWithCache,
    );
  }

  List<MediaItem> get movies =>
      items.where((i) => i.type == MediaType.movie).toList();

  List<MediaItem> get series =>
      items.where((i) => i.type == MediaType.series).toList();
}

class MediaLibraryNotifier extends StateNotifier<MediaLibraryState> {
  final MediaScanner _scanner;
  final Ref _ref;

  // Cooperative cancel flag for the current thumbnail-generation run.
  // Set by `cancelThumbnailGeneration()` and checked by every worker
  // between videos. This lets the user abort a long-running pass
  // (e.g. first-time scan of a 200-episode library) without waiting
  // for ffmpeg to finish the video it's currently chewing on. We still
  // let the in-flight ffmpeg process complete its current file rather
  // than killing it mid-write — half-written jpgs + a .done marker
  // would be worse than just finishing cleanly.
  bool _cancelThumbnails = false;
  bool get isCancellingThumbnails => _cancelThumbnails;

  // Intentionally no auto-scan in the constructor.
  //
  // Earlier versions kicked off `scanLibrary()` from `_init()` here, AND
  // HomeScreen's `initState` also fires a `refresh()` via postFrameCallback
  // to pick up newly added files on every app start. Those two triggers
  // raced: if the first scan completed within one frame, the postFrameCallback
  // fired a SECOND `scanLibrary()` whose `_generateThumbnails()` ran
  // concurrently with the first — both tried to generate for the same
  // newly-added videos, `isGeneratingThumbnails` flip-flopped, and the
  // progress banner never appeared. Users had to hit "Aktualisieren"
  // manually to get thumbnails for newly added files.
  //
  // HomeScreen is now the single source of truth for the initial scan.
  MediaLibraryNotifier(this._ref)
      : _scanner = MediaScanner(),
        super(MediaLibraryState(
          manuallyClearedPaths: _loadManuallyCleared(),
        ));

  /// Best-effort read of persisted manually-cleared paths. Returns an
  /// empty set if the box isn't open or the key is missing — never
  /// throws, because a corrupted entry should not prevent the app
  /// from starting.
  static Set<String> _loadManuallyCleared() {
    try {
      final box = Hive.box('settings');
      final raw = box.get(_kManuallyClearedKey);
      if (raw is List) {
        return raw.whereType<String>().toSet();
      }
    } catch (_) {/* fall through */}
    return <String>{};
  }

  Future<void> _persistManuallyCleared(Set<String> paths) async {
    try {
      final box = Hive.box('settings');
      await box.put(_kManuallyClearedKey, paths.toList());
    } catch (_) {/* non-fatal — in-memory state is still correct */}
  }

  Future<void> scanLibrary(String path) async {
    // Guard against concurrent scans (e.g. user mashing the refresh button).
    // Two scans racing would both run the orphan-prune which could briefly
    // flash inconsistent state.
    if (state.isLoading) return;
    state = state.copyWith(
      isLoading: true,
      error: null,
      clearThumbnailWarning: true,
    );
    try {
      // Fail fast with a user-friendly message if the folder vanished
      // (external drive unplugged, network share offline, ...).
      if (!await Directory(path).exists()) {
        state = state.copyWith(
          isLoading: false,
          error:
              'Medien-Ordner nicht gefunden:\n$path\n\nIst die Festplatte oder das Netzlaufwerk noch verbunden?',
        );
        return;
      }
      final items = await _scanner.scanDirectory(path);

      // Upsert history BEFORE cleanup so keepCache flags + historic
      // paths for removed-media-sparing are up to date. Returns a
      // per-item change-bundle list that we surface to the UI so the
      // user can decide cache reset on a re-appeared modified item.
      List<MediaChangeBundle> changes = const [];
      try {
        // New items default to NOT flagged. Users explicitly flag what
        // they want to keep via the "Für Behaltung geflagt" section —
        // aligning with the "flag is the single source of truth" rule
        // introduced in 1.4.2 (the old global toggle was removed
        // because it duplicated + overwrote per-item flags).
        changes = await _ref
            .read(mediaHistoryProvider.notifier)
            .upsertFromLibrary(items, defaultKeepForNew: false);
      } catch (_) {
        // History failure is non-fatal — scan must keep working even if
        // the history box is wedged. Changes stay empty, nothing lost.
      }

      // Inject "manuelle Reset"-paths as synthetic modified changes so
      // the user sees a single unified dialog instead of silently
      // regenerating caches they just deleted. We only surface paths
      // that still exist in the current library (otherwise the file
      // is gone and orphan cleanup handles it).
      final manualPaths = state.manuallyClearedPaths;
      if (manualPaths.isNotEmpty) {
        final bundles = _buildManualResetBundles(items, manualPaths);
        if (bundles.isNotEmpty) {
          changes = [...changes, ...bundles];
        }
      }

      state = state.copyWith(
        items: items,
        isLoading: false,
        pendingChanges: changes,
      );

      // Clean up thumbnails + watch progress for videos no longer in the
      // library. AWAITED so generation never races a concurrent delete —
      // earlier versions fire-and-forgot this, which on slow disks could
      // mean the generator checked `hasThumbnails` while cleanup was
      // mid-delete, saw an incomplete cache folder, nuked the marker,
      // and queued a full rebuild — a likely cause of the "0/alle
      // Episoden" banner the user reported after a single-episode reset.
      await _cleanupOrphanedThumbnails(items);
      await _pruneOrphanedProgress(items);

      // Compute the set of paths that currently HAVE a cache on disk,
      // so the settings reset-tree can render only entries the user
      // can actually reset. Includes both current and archived paths.
      final cached = await _computePathsWithCache(items);
      state = state.copyWith(pathsWithCache: cached);

      // IMPORTANT: if there are pending structural changes, do NOT auto-
      // generate thumbnails. The user needs to decide in the dialog
      // whether new/modified episodes should get a fresh cache — if we
      // ran generation in parallel, the "new" entries would already be
      // half-built by the time the user even reads the checkboxes, and
      // unchecking them would feel like it did nothing (see the
      // Fargo.mkv→Fargo.mp4 case). Generation resumes via
      // [applyChangeDecisions] or is skipped entirely on
      // [skipChangeDecisions] / [dismissPendingChanges].
      if (changes.isNotEmpty) {
        return;
      }

      // No pending changes → auto-generate as before.
      //
      // Wrapped so any unhandled exception (broken VERSIONINFO causing
      // path_provider to throw, missing ffmpeg permissions, Hive locked, …)
      // surfaces as a user-visible warning instead of disappearing silently
      // into the fire-and-forget void.
      _generateThumbnails(items).catchError((e, st) {
        if (!mounted) return;
        // Typical culprits (each has a distinctive exception text):
        //   - "Unable to get application support path" → exe has no
        //     CompanyName/ProductName VERSIONINFO; common when running a
        //     hand-copied dev build instead of the installed version.
        //   - FileSystemException → disk full / permissions.
        final msg = e.toString();
        final actionable = msg.contains('application support path')
            ? 'Die App kann den eigenen Datenordner nicht finden. Das passiert '
                'typischerweise wenn die .exe ohne Installer benutzt wird oder '
                'die Versionsinformation fehlt. Bitte den offiziellen Installer '
                '(BeefburgerStreamingSetup-x.y.z.exe) ausführen und darüber '
                'starten.'
            : 'Vorschaubild-Generierung konnte nicht starten:\n\n$e';
        state = state.copyWith(
          isGeneratingThumbnails: false,
          thumbnailWarning: actionable,
        );
      });
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Fehler beim Scannen: $e',
      );
    }
  }

  /// Collects all current video paths and removes cached thumbnail folders
  /// for videos that no longer exist in the library. Respects both the
  /// global "Cache für entfernte Medien behalten" setting and the
  /// per-item keepCache flags — cache for those paths survives cleanup.
  Future<void> _cleanupOrphanedThumbnails(List<MediaItem> items) async {
    final currentPaths = <String>{};
    for (final item in items) {
      if (item.type == MediaType.movie && item.movieFilePath != null) {
        currentPaths.add(item.movieFilePath!);
      } else if (item.type == MediaType.series) {
        for (final ep in item.allEpisodes) {
          currentPaths.add(ep.filePath);
        }
      }
    }

    // Build the "spare set": paths whose cache folders should survive
    // even though they are no longer in `currentPaths`.
    //
    // Rule: **per-item keepCache flag is the sole source of truth**.
    // The global "Cache für entfernte Medien behalten" setting only
    // controls the DEFAULT flag for newly-seen items (see
    // mediaHistoryProvider.upsertFromLibrary) and triggers a bulk
    // flip when the user toggles it in Settings. At cleanup time,
    // whatever flag the item carries wins — global is not re-read
    // here. This matches the user model "Flag überschreibt global".
    final historyNotifier = _ref.read(mediaHistoryProvider.notifier);
    final sparePaths = <String>{}
      ..addAll(historyNotifier.keptVideoPaths);

    try {
      await ThumbnailService.instance
          .cleanupOrphaned(currentPaths, sparePaths: sparePaths);
    } catch (_) {
      // Non-fatal — just skip cleanup on failure
    }
  }

  /// Drops "Weiterschauen" entries pointing to videos that no longer exist
  /// in the scanned library, so deleted files don't leave ghost tiles behind.
  Future<void> _pruneOrphanedProgress(List<MediaItem> items) async {
    final validPaths = <String>{};
    for (final item in items) {
      if (item.type == MediaType.movie && item.movieFilePath != null) {
        validPaths.add(item.movieFilePath!);
      } else if (item.type == MediaType.series) {
        for (final ep in item.allEpisodes) {
          validPaths.add(ep.filePath);
        }
      }
    }
    try {
      await _ref.read(watchProgressProvider.notifier).pruneOrphaned(validPaths);
    } catch (_) {
      // Non-fatal
    }
  }

  /// [onlyPaths] restricts the generation pass to videos whose path is
  /// in the set. Used by [applyChangeDecisions] so a user-confirmed
  /// dialog rebuild only touches the paths the user ticked — not every
  /// cache-less file in the library (which would e.g. re-generate new
  /// "added" episodes the user unchecked).
  Future<void> _generateThumbnails(
    List<MediaItem> items, {
    Set<String>? onlyPaths,
  }) async {
    // Honor user setting — skip entirely if thumbnails are disabled.
    final settings = _ref.read(settingsProvider);
    if (!settings.thumbnailsEnabled) return;

    final service = ThumbnailService.instance;
    await service.initialize();

    // On iOS we don't ship ffmpeg (sandboxed apps can't spawn child
    // processes anyway). Thumbnail generation for the home-screen
    // grid and seekbar previews is handled via AVAssetImageGenerator
    // in a later phase; for now just no-op cleanly and avoid showing
    // a "FFmpeg missing" banner that the user can't do anything about.
    if (Platform.isIOS) return;

    final ffmpeg = await service.findFFmpeg();

    if (ffmpeg == null) {
      state = state.copyWith(ffmpegMissing: true);
      return;
    }

    bool included(String p) => onlyPaths == null || onlyPaths.contains(p);

    // Collect all video paths that still need thumbnails
    final videosToProcess = <({String path, String label})>[];
    for (final item in items) {
      if (item.type == MediaType.movie && item.movieFilePath != null) {
        if (included(item.movieFilePath!) &&
            !await service.hasThumbnails(item.movieFilePath!)) {
          videosToProcess.add((path: item.movieFilePath!, label: item.title));
        }
      } else if (item.type == MediaType.series) {
        for (final ep in item.allEpisodes) {
          if (included(ep.filePath) &&
              !await service.hasThumbnails(ep.filePath)) {
            videosToProcess.add((
              path: ep.filePath,
              label: '${item.title} · ${ep.displayName}',
            ));
          }
        }
      }
    }

    if (videosToProcess.isEmpty) return;

    // Pre-flight disk-write probe. If the cache dir isn't writable, skip
    // generation entirely rather than thrashing ffmpeg through 84 failing
    // attempts — and tell the user why.
    final writeError = await service.probeWritable();
    if (writeError != null) {
      state = state.copyWith(thumbnailWarning: writeError);
      return;
    }

    // Fresh cancel flag for this run — users who hit "Stopp" on the
    // previous run shouldn't have the flag stick and abort the next
    // one before a single worker starts.
    _cancelThumbnails = false;

    state = state.copyWith(
      isGeneratingThumbnails: true,
      thumbnailsCurrent: 0,
      thumbnailsTotal: videosToProcess.length,
      currentThumbnailLabel: videosToProcess.first.label,
      ffmpegMissing: false,
    );

    // Parallel workers: process multiple videos concurrently.
    //
    // Individual ffmpeg failures are EXPECTED for some inputs (ISO images,
    // codec quirks, corrupted files) and are not the user's problem. We
    // silently skip those and move on. The only thing that should interrupt
    // generation and alert the user is the cache suddenly becoming
    // unwritable mid-run (disk filling up during work). We detect that by
    // re-probing only after a lot of back-to-back failures — far above
    // normal "a few bad files in the library" noise.
    const concurrency = 4;
    const abortThreshold = 15; // consecutive failures before we suspect disk
    int nextIndex = 0;
    int completed = 0;
    int consecutiveFailures = 0;
    int totalFailures = 0;
    bool aborted = false;
    // Keep the first failure reason so we can surface it to the user when
    // the whole (typically small) batch fails. Invaluable for the
    // "added one new file, ffmpeg can't read it" case — otherwise the
    // banner would disappear with no explanation.
    String? firstFailureLabel;
    String? firstFailureReason;

    Future<void> worker() async {
      while (true) {
        if (!mounted || aborted) return;
        // Honor user-requested cancel between videos. We don't
        // interrupt the ffmpeg process itself — killing it mid-write
        // can leave a partial jpg + premature .done marker that would
        // pass the later `hasThumbnails` check and we'd never
        // regenerate. Aborting between files is safe and quick.
        if (_cancelThumbnails) {
          aborted = true;
          return;
        }
        final i = nextIndex++;
        if (i >= videosToProcess.length) return;
        final video = videosToProcess[i];
        // Show the most recently STARTED label (approximates current work).
        state = state.copyWith(currentThumbnailLabel: video.label);
        final ok = await service.generateForVideo(video.path);
        if (!mounted) return;
        completed++;
        if (ok) {
          consecutiveFailures = 0;
          // Keep [pathsWithCache] current so the reset tree picks up
          // freshly built caches without waiting for the next scan.
          final updated = <String>{...state.pathsWithCache, video.path};
          state = state.copyWith(pathsWithCache: updated);
        } else {
          consecutiveFailures++;
          totalFailures++;
          firstFailureLabel ??= video.label;
          firstFailureReason ??= service.lastErrorMessage;
          if (consecutiveFailures >= abortThreshold) {
            // Only treat as a real problem if the cache is now unwritable —
            // otherwise it's just a cluster of bad source files, keep going.
            final writeError = await service.probeWritable();
            if (writeError != null) {
              aborted = true;
              if (mounted) {
                state = state.copyWith(thumbnailWarning: writeError);
              }
              return;
            }
            // Reset so we don't re-probe constantly if the bad run continues.
            consecutiveFailures = 0;
          }
        }
        state = state.copyWith(thumbnailsCurrent: completed);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));

    if (!mounted) return;
    state = state.copyWith(
      isGeneratingThumbnails: false,
      thumbnailsCurrent: aborted ? completed : videosToProcess.length,
      currentThumbnailLabel: null,
    );

    // Post-run summary: surface something whenever failures happened. In a
    // large library a few codec / ISO failures are noise, so we only warn
    // above a majority-failure ratio. But for small batches (typically the
    // "user just added one new file on app start" case), every failure
    // matters — silently eating a single-file failure means the user sees
    // the banner flash briefly and then nothing happens, with no
    // explanation why their new movie has no preview thumbnails.
    if (!aborted && totalFailures > 0) {
      final ratio = totalFailures / videosToProcess.length;
      final smallBatchAllFailed =
          videosToProcess.length < 5 && totalFailures == videosToProcess.length;
      final bigBatchMajorityFailed =
          videosToProcess.length >= 5 && ratio >= 0.5;
      if (smallBatchAllFailed || bigBatchMajorityFailed) {
        final buf = StringBuffer()
          ..write(
            'Für $totalFailures von ${videosToProcess.length} Datei(en) '
            'konnten keine Vorschaubilder erstellt werden.',
          );
        if (firstFailureLabel != null) {
          buf.write(' Erste betroffene Datei: $firstFailureLabel.');
        }
        if (firstFailureReason != null && firstFailureReason!.isNotEmpty) {
          buf.write('\n\nFFmpeg-Meldung: $firstFailureReason');
        } else {
          buf.write(
            '\n\nDie Datei ist möglicherweise beschädigt oder verwendet '
            'ein Format, das FFmpeg nicht lesen kann (häufig bei '
            '.iso-Dateien).',
          );
        }
        state = state.copyWith(thumbnailWarning: buf.toString());
      }
    }
  }

  /// Clears the active thumbnail warning after the user has acknowledged it.
  void dismissThumbnailWarning() {
    if (state.thumbnailWarning == null) return;
    state = state.copyWith(clearThumbnailWarning: true);
  }

  /// Clears the pending-changes list once the user has handled the
  /// change-detection dialog (either decided or dismissed). Safe to
  /// call repeatedly — doesn't trigger generation on its own.
  void dismissPendingChanges() {
    if (state.pendingChanges.isEmpty && state.manuallyClearedPaths.isEmpty) {
      return;
    }
    state = state.copyWith(
      pendingChanges: const [],
      manuallyClearedPaths: const {},
    );
    _persistManuallyCleared(const <String>{});
  }

  /// User clicked "Abbrechen" in the change dialog — discard the
  /// pending list WITHOUT running cleanup or generation. The library
  /// state keeps whatever the scan found so the user can look around;
  /// a later refresh (manual or folder change) re-triggers the
  /// detection.
  void skipChangeDecisions() {
    dismissPendingChanges();
  }

  /// User clicked "Aktionen durchführen". Apply the per-change
  /// selections from the dialog:
  ///   - [pathsToDelete]: affected paths of "removed" changes the user
  ///     ticked. Cache is purged; no regeneration (file is gone).
  ///   - [pathsToRebuild]: affected paths of "modified"/"added" changes
  ///     the user ticked. Existing cache is purged, then fresh
  ///     thumbnails are generated — but ONLY for these paths, so
  ///     unticked entries don't sneak back in.
  Future<void> applyChangeDecisions({
    required Set<String> pathsToDelete,
    required Set<String> pathsToRebuild,
  }) async {
    final toClear = <String>{...pathsToDelete, ...pathsToRebuild};
    if (toClear.isNotEmpty) {
      try {
        await ThumbnailService.instance.clearCacheForPaths(toClear);
      } catch (_) {
        // Non-fatal — continue to generation anyway.
      }
    }
    state = state.copyWith(
      pendingChanges: const [],
      manuallyClearedPaths: const {},
    );
    await _persistManuallyCleared(const <String>{});
    if (pathsToRebuild.isNotEmpty) {
      _generateThumbnails(state.items, onlyPaths: pathsToRebuild)
          .catchError((e, st) {
        if (!mounted) return;
        state = state.copyWith(
          isGeneratingThumbnails: false,
          thumbnailWarning: 'Vorschaubild-Generierung konnte nicht starten:\n\n$e',
        );
      });
    }
  }

  /// Removes cache + history entries for every archive item (= in
  /// history but not in the current library) whose keepCache flag is
  /// NOT set. Used by the "Allgemein-toggle wird deaktiviert"-Dialog.
  Future<int> cleanUnflaggedArchive() async {
    final currentIds = {for (final i in state.items) i.id};
    final historyNotifier = _ref.read(mediaHistoryProvider.notifier);
    final victims = historyNotifier
        .historicItemsMissingFrom(currentIds)
        .where((m) => !m.keepCache)
        .toList();
    if (victims.isEmpty) return 0;
    final paths = <String>{};
    for (final v in victims) {
      paths.addAll(v.allVideoPaths);
    }
    try {
      await ThumbnailService.instance.clearCacheForPaths(paths);
    } catch (_) {}
    for (final v in victims) {
      await historyNotifier.removeEntry(v.mediaId);
    }
    return victims.length;
  }

  /// User chose "Cache neu erstellen" for one change bundle / one
  /// specific change entry. Deletes the affected folders and kicks
  /// off a refresh so the next scan regenerates them.
  ///
  /// [triggerRefresh] controls whether a library scan runs afterwards:
  ///  - `true` (default): regeneration starts immediately — correct for
  ///    the post-scan "cache veraltet" dialog where the user explicitly
  ///    asked us to rebuild stale thumbnails.
  ///  - `false`: just purge on disk. The paths are recorded in
  ///    [manuallyClearedPaths] so the NEXT library scan routes them
  ///    through the change-dialog (Variante A) instead of silently
  ///    regenerating. Keeps the semantics consistent with folder-
  ///    detected changes: all cache rebuilds require an explicit
  ///    user confirmation.
  Future<void> resetCacheForPaths(
    Iterable<String> paths, {
    bool triggerRefresh = true,
  }) async {
    await ThumbnailService.instance.clearCacheForPaths(paths);
    // Reflect the disk change in [pathsWithCache] immediately so the
    // reset tree hides the entry without waiting for a full rescan.
    final pathSet = paths.toSet();
    final stillCached = state.pathsWithCache
        .where((p) => !pathSet.contains(p))
        .toSet();
    state = state.copyWith(pathsWithCache: stillCached);

    if (triggerRefresh) {
      await refresh();
    } else {
      // Remember so the next scan surfaces these via the dialog —
      // persisted so it survives app restart.
      final updated = <String>{...state.manuallyClearedPaths, ...paths};
      state = state.copyWith(manuallyClearedPaths: updated);
      await _persistManuallyCleared(updated);
    }
  }

  /// Walks every candidate video path (current library + history) and
  /// asks the thumbnail service which ones actually have a cache on
  /// disk. This is the source-of-truth the reset tree renders from;
  /// without it the tree could offer "reset Serie X" on a series
  /// whose cache is already empty, which is confusing and error-prone.
  Future<Set<String>> _computePathsWithCache(List<MediaItem> items) async {
    final service = ThumbnailService.instance;
    await service.initialize();
    final candidates = <String>{};
    for (final item in items) {
      if (item.type == MediaType.movie && item.movieFilePath != null) {
        candidates.add(item.movieFilePath!);
      } else if (item.type == MediaType.series) {
        for (final ep in item.allEpisodes) {
          candidates.add(ep.filePath);
        }
      }
    }
    try {
      // Also include archive (= history entries not in current library).
      final history = _ref.read(mediaHistoryProvider);
      final currentIds = {for (final i in items) i.id};
      for (final m in history) {
        if (currentIds.contains(m.mediaId)) continue;
        candidates.addAll(m.allVideoPaths);
      }
    } catch (_) {/* history unavailable — skip archive */}

    final withCache = <String>{};
    for (final path in candidates) {
      if (await service.hasThumbnails(path)) {
        withCache.add(path);
      }
    }
    return withCache;
  }

  /// Converts an in-memory set of user-reset paths into synthetic
  /// MediaChangeBundles so the change dialog can present them
  /// uniformly next to folder-detected changes. Only paths that still
  /// exist in the current library are surfaced — if the file is gone
  /// too, orphan cleanup handles it and we skip.
  List<MediaChangeBundle> _buildManualResetBundles(
    List<MediaItem> items,
    Set<String> manualPaths,
  ) {
    final out = <MediaChangeBundle>[];
    for (final item in items) {
      final changes = <MediaChange>[];
      if (item.type == MediaType.movie &&
          item.movieFilePath != null &&
          manualPaths.contains(item.movieFilePath!)) {
        changes.add(MediaChange(
          description: 'Manuell zurückgesetzt — Cache ist leer',
          affectedPaths: [item.movieFilePath!],
          kind: MediaChangeKind.modified,
        ));
      } else if (item.type == MediaType.series) {
        for (final s in item.seasons) {
          for (final ep in s.episodes) {
            if (manualPaths.contains(ep.filePath)) {
              changes.add(MediaChange(
                description:
                    'Staffel ${s.number} · Episode ${ep.episodeNumber} · manuell zurückgesetzt',
                affectedPaths: [ep.filePath],
                kind: MediaChangeKind.modified,
              ));
            }
          }
        }
      }
      if (changes.isNotEmpty) {
        out.add(MediaChangeBundle(
          mediaId: item.id,
          title: item.title,
          changes: changes,
        ));
      }
    }
    return out;
  }

  /// Request the running thumbnail generation to stop. No-op if nothing
  /// is generating right now. Workers check the flag between videos and
  /// bail out within one file. Idempotent — calling it repeatedly is
  /// safe and doesn't queue up anything.
  void cancelThumbnailGeneration() {
    if (!state.isGeneratingThumbnails) return;
    _cancelThumbnails = true;
  }

  Future<void> refresh() async {
    final settings = _ref.read(settingsProvider);
    if (settings.mediaFolderPath == null) return;

    // iOS-only: the app's Documents container lives at a path that
    // includes a UUID (e.g. /var/mobile/Containers/Data/Application/
    // <UUID>/Documents). iOS may change that UUID across reinstalls /
    // re-signings (Sideloadly flips the signing cert) — at which point
    // the stored absolute path is dead and the scanner bails with
    // "Medien-Ordner nicht gefunden".
    //
    // The user-facing concept of the media folder on iOS is "the folder
    // the Files app shows under BeefburgerStreaming", which is always
    // the *current* Documents dir. So if the stored path looks stale,
    // we silently re-resolve and persist it.
    var path = settings.mediaFolderPath!;
    if (Platform.isIOS) {
      path = await _resolveIOSMediaFolder(path);
    }
    await scanLibrary(path);
  }

  /// iOS: maps an old container-Documents path to the *current* one,
  /// handling the case where iOS has rotated the container UUID between
  /// launches. No-op for paths that already resolve or that live
  /// outside the app container (the latter shouldn't happen because the
  /// iOS picker always returns Documents, but we don't want to rewrite
  /// paths we don't fully understand).
  Future<String> _resolveIOSMediaFolder(String stored) async {
    try {
      if (await Directory(stored).exists()) return stored;
      final docs = (await getApplicationDocumentsDirectory()).path;
      // Heuristic: the stored path is a container Documents path if it
      // contains "/Containers/Data/Application/" and ends with
      // "/Documents" (or a subpath thereof). Remap by replacing the
      // old container prefix with the new Documents dir, preserving
      // any user-chosen subfolder after "/Documents".
      final marker = RegExp(r'/Containers/Data/Application/[^/]+/Documents');
      final m = marker.firstMatch(stored);
      final String remapped;
      if (m != null) {
        remapped = docs + stored.substring(m.end);
      } else {
        // Unknown shape — fall back to bare Documents so the user
        // always has a usable library instead of a dead-end error.
        remapped = docs;
      }
      // Persist so the next launch doesn't have to remap again.
      await _ref.read(settingsProvider.notifier).setMediaFolderPath(remapped);
      return remapped;
    } catch (_) {
      // Any failure here is non-fatal — fall through to the normal
      // "folder missing" error path with the original stored value.
      return stored;
    }
  }

  /// Called after the *entire* thumbnail cache has been purged from
  /// disk (Settings → "Vorschaubild-Cache leeren"). Flushes the
  /// in-memory `pathsWithCache` set so the per-item reset tree and the
  /// keep-flag list immediately reflect "nothing cached anywhere"
  /// instead of still showing every former entry. Without this the
  /// menus kept rendering archived entries the user just deleted —
  /// the exact "ich hab geleert, warum steht das noch da" report.
  void notifyAllCachesCleared() {
    if (state.pathsWithCache.isEmpty) return;
    state = state.copyWith(pathsWithCache: const <String>{});
  }

  MediaItem? getById(String id) {
    try {
      return state.items.firstWhere((i) => i.id == id);
    } catch (_) {
      return null;
    }
  }
}

final mediaLibraryProvider =
    StateNotifierProvider<MediaLibraryNotifier, MediaLibraryState>((ref) {
  return MediaLibraryNotifier(ref);
});
