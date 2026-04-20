import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Generates and caches seekbar preview thumbnails using FFmpeg.
class ThumbnailService {
  static ThumbnailService? _instance;
  // Plain `String?` (not `late final`) on purpose: two concurrent callers
  // both entering `initialize()` simultaneously would otherwise race on the
  // late-final assignment and the second one crashes with
  // `LateInitializationError: Field '_cacheDir' has already been
  // initialized.` — which then bubbles up as a completely opaque "thumbnail
  // generation silently stopped" bug for the user. The `_initFuture` below
  // de-dupes concurrent initialize() calls so only the first actually does
  // the work, subsequent callers just await the same Future.
  String? _cacheDir;
  Future<void>? _initFuture;
  String? _ffmpegPath;
  bool _ffmpegChecked = false;

  /// Seconds between thumbnails.
  static const int intervalSeconds = 10;

  /// Thumbnail dimensions (keeping aspect ratio-ish).
  static const int thumbWidth = 240;
  static const int thumbHeight = 135;

  /// In-flight ffmpeg child processes. Tracked so we can kill them all
  /// on app shutdown — otherwise a Windows user who closes the app
  /// during a long generation run can be left with an orphan ffmpeg
  /// chewing on their external drive for minutes, and (worse) the
  /// `.done` marker file might get written by a zombie process long
  /// after the user thinks the app is gone.
  final Set<Process> _liveProcesses = {};

  /// Kills every in-flight ffmpeg child. Call from the app-level
  /// onWindowClose hook. Safe to call with no live processes.
  Future<void> killAllInFlight() async {
    for (final p in List<Process>.from(_liveProcesses)) {
      try {
        p.kill(ProcessSignal.sigkill);
      } catch (_) {/* best-effort */}
    }
    _liveProcesses.clear();
  }

  ThumbnailService._();

  static ThumbnailService get instance {
    _instance ??= ThumbnailService._();
    return _instance!;
  }

  Future<void> initialize() {
    // Cache the in-flight Future so that parallel callers all await the
    // same work rather than each trying to run setup. Concurrency is the
    // norm here: a library scan calls this, `getCacheSize` in settings
    // calls this, every `hasThumbnails` in the worker loop calls this.
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = p.join(appDir.path, 'thumbnails');
    await Directory(dir).create(recursive: true);
    _cacheDir = dir;
  }

  /// Writability probe used before bulk thumbnail generation. Returns null
  /// if the cache directory accepts writes, or a human-friendly error
  /// message if not (most commonly "disk full" or permissions).
  ///
  /// Implementation notes:
  /// - Unique filename (timestamp) so a leftover probe file from a crashed
  ///   previous run or a concurrent call can't cause false negatives.
  /// - Cleanup failure is ignored: if the write succeeded, the directory IS
  ///   writable — a delete hiccup (e.g. AV scanner holding the file for a
  ///   few ms) does not mean "not writable".
  /// - We ensure the cache dir exists first; `clearCache` + a later probe
  ///   otherwise race on Windows where `delete(recursive:true)` can leave
  ///   the directory handle briefly in a transitional state.
  Future<String?> probeWritable() async {
    await initialize();
    // Make sure the dir exists — `clearCache` recreates it but if anything
    // outside the app has wiped it, create on demand.
    try {
      await Directory(_cacheDir!).create(recursive: true);
    } catch (_) {/* handled below when the write itself fails */}

    final name = '.write-test-${DateTime.now().microsecondsSinceEpoch}';
    final probe = File(p.join(_cacheDir!, name));
    try {
      // 4 KB — small enough to succeed on "almost full", large enough to
      // reliably trip a full disk.
      await probe.writeAsBytes(List<int>.filled(4096, 0), flush: true);
    } on FileSystemException catch (e) {
      // Windows: OS error 112 = ERROR_DISK_FULL, 39 = ERROR_HANDLE_DISK_FULL.
      final code = e.osError?.errorCode ?? 0;
      if (code == 112 || code == 39) {
        return 'Festplatte voll — es können keine Vorschaubilder erstellt werden. '
            'Bitte Speicherplatz freigeben und die Bibliothek erneut aktualisieren.';
      }
      return 'Cache-Ordner nicht beschreibbar: ${e.message}';
    } catch (e) {
      return 'Cache-Ordner nicht beschreibbar: $e';
    }
    // Best-effort cleanup — don't fail the probe on delete errors.
    try {
      await probe.delete();
    } catch (_) {/* no-op */}
    return null;
  }

  /// Returns path to ffmpeg binary or null if not found.
  Future<String?> findFFmpeg() async {
    if (_ffmpegChecked) return _ffmpegPath;
    _ffmpegChecked = true;

    // 1. Check bundled ffmpeg next to executable
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final bundled = p.join(exeDir, 'ffmpeg.exe');
      if (await File(bundled).exists()) {
        _ffmpegPath = bundled;
        return _ffmpegPath;
      }
      // Also check common subfolders
      for (final sub in ['ffmpeg', 'bin', 'data/ffmpeg']) {
        final candidate = p.join(exeDir, sub, 'ffmpeg.exe');
        if (await File(candidate).exists()) {
          _ffmpegPath = candidate;
          return _ffmpegPath;
        }
      }
    } catch (_) {}

    // 2. Check system PATH
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        ['ffmpeg'],
      );
      if (result.exitCode == 0) {
        final output = result.stdout.toString().trim();
        final firstLine = output.split('\n').first.trim();
        if (firstLine.isNotEmpty && await File(firstLine).exists()) {
          _ffmpegPath = firstLine;
          return _ffmpegPath;
        }
      }
    } catch (_) {}

    // 3. Common install locations (Windows)
    if (Platform.isWindows) {
      final common = [
        'C:\\ffmpeg\\bin\\ffmpeg.exe',
        'C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe',
        'C:\\Program Files (x86)\\ffmpeg\\bin\\ffmpeg.exe',
      ];
      for (final path in common) {
        if (await File(path).exists()) {
          _ffmpegPath = path;
          return _ffmpegPath;
        }
      }
    }

    return null;
  }

  bool get isFFmpegAvailable => _ffmpegPath != null;

  /// Returns the cache directory for thumbnails of a given video.
  ///
  /// Uses FNV-1a 64-bit — a deterministic hash that returns the same value
  /// across process restarts. This is CRITICAL: `String.hashCode` in the
  /// Dart VM is seeded randomly per isolate, so relying on it means the
  /// cache folder name changes every launch and all cached thumbnails
  /// appear "orphaned" on the next scan.
  String _videoCacheDir(String videoPath) {
    // Windows paths are case-insensitive on the filesystem AND can be
    // written with either `\` or `/` (Scanner yields backslashes via
    // `p.join`, but user-provided or legacy data may still carry
    // forward slashes). If we hashed those variants separately the
    // cache would appear "orphaned" after any rescan that yielded a
    // different spelling of the same path, and `hasThumbnails` would
    // report false for every episode — manifesting as the infamous
    // "0 / <alle Episoden>" banner on refresh.
    //
    // Canonicalise aggressively: run through `p.normalize` (collapses
    // `..` / redundant separators), unify the separator to `\` on
    // Windows, and lowercase. The resulting string is what we hash.
    String normalized = p.normalize(videoPath);
    if (Platform.isWindows) {
      normalized = normalized.replaceAll('/', '\\').toLowerCase();
    }
    final bytes = normalized.codeUnits;

    // FNV-1a 64-bit. Using BigInt keeps this portable and overflow-safe
    // on both native and web runtimes.
    final mask = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
    final prime = BigInt.parse('100000001B3', radix: 16);
    BigInt hash = BigInt.parse('CBF29CE484222325', radix: 16);
    for (final c in bytes) {
      hash = (hash ^ BigInt.from(c)) & mask;
      hash = (hash * prime) & mask;
    }
    final folderName =
        '${normalized.length}_${hash.toRadixString(16).padLeft(16, '0')}';
    return p.join(_cacheDir!, folderName);
  }

  /// True if thumbnails have already been generated for this video.
  ///
  /// Checks both:
  ///  1. the `.done` marker file exists, AND
  ///  2. at least one actual `thumb_*.jpg` file exists alongside it.
  ///
  /// The second check is the self-healing part. In rare cases we've seen a
  /// `.done` file survive in a cache folder that has NO real thumbnails:
  ///   - Windows file locks (Explorer / AV scanner) can cause
  ///     `cleanupOrphaned`'s `delete(recursive:true)` to silently fail,
  ///     leaving behind a half-nuked folder.
  ///   - An older app version that wrote `.done` on partial / empty
  ///     generation (pre-1.2.0 bug).
  ///   - User manually deleting thumbnails but not the marker.
  /// Any of those states would make us report "thumbnails exist" and skip
  /// generation silently — user sees no banner, no error, no thumbnails.
  /// Treating the folder as invalid instead triggers a clean regeneration.
  ///
  /// On the hot path (every scan walks every video) the extra check is still
  /// cheap: only the marker-exists branch actually lists the directory, and
  /// `listSync().any(...)` short-circuits on the first match.
  Future<bool> hasThumbnails(String videoPath) async {
    await initialize();
    final dir = _videoCacheDir(videoPath);
    final doneMarker = File(p.join(dir, '.done'));
    if (!await doneMarker.exists()) return false;

    try {
      final directory = Directory(dir);
      // Short-circuit: we only need to know "at least one jpg" — not count them.
      final hasAnyThumb = directory
          .listSync(followLinks: false)
          .whereType<File>()
          .any((f) => p.basename(f.path).startsWith('thumb_') &&
              f.path.toLowerCase().endsWith('.jpg'));
      if (hasAnyThumb) return true;

      // Marker without thumbnails is a corrupt cache entry. Remove the
      // stale marker so the next generation run treats this as fresh work
      // and actually produces output.
      try {
        await doneMarker.delete();
      } catch (_) {/* best-effort */}
      return false;
    } catch (_) {
      // If we can't even list the directory, err on "no thumbnails" — the
      // generator will try to recreate and surface a real error if it can't.
      return false;
    }
  }

  /// Returns the path to the thumbnail closest to the given position.
  /// Returns null if no thumbnail exists at that position.
  Future<String?> getThumbnailAt(String videoPath, Duration position) async {
    await initialize();
    final dir = _videoCacheDir(videoPath);
    // Thumbnails are 1-indexed: thumb_0001.jpg at t=0, thumb_0002.jpg at t=10, ...
    final index = (position.inSeconds ~/ intervalSeconds) + 1;
    final padded = index.toString().padLeft(5, '0');
    final path = p.join(dir, 'thumb_$padded.jpg');
    if (await File(path).exists()) return path;
    return null;
  }

  /// Generate thumbnails for a single video. Returns true on success.
  ///
  /// On failure, [lastErrorMessage] is populated with the first few lines of
  /// ffmpeg's stderr (or a description of what went wrong), so the caller can
  /// surface it in a user-facing warning — invaluable for the "only one file
  /// failed" case where the banner would otherwise silently vanish.
  String? lastErrorMessage;

  Future<bool> generateForVideo(String videoPath) async {
    await initialize();
    final ffmpeg = await findFFmpeg();
    if (ffmpeg == null) {
      lastErrorMessage = 'FFmpeg nicht gefunden';
      return false;
    }

    // Skip if already generated
    if (await hasThumbnails(videoPath)) return true;

    // Defensive: skip up-front if the source file vanished between scan and
    // generation (e.g. external drive unplugged, user moved files).
    if (!await File(videoPath).exists()) {
      lastErrorMessage = 'Datei nicht gefunden: $videoPath';
      return false;
    }

    final dir = _videoCacheDir(videoPath);
    await Directory(dir).create(recursive: true);

    Process? proc;
    try {
      // `ProcessStartMode.normal` (the default) is required: `detached*`
      // modes do NOT provide a reliable exit code, which caused every
      // generation to look like a failure. We still drain stdio below so
      // full pipe buffers can't deadlock the child.
      proc = await Process.start(
        ffmpeg,
        [
          '-loglevel', 'error',
          '-y', // overwrite
          '-i', videoPath,
          '-vf', 'fps=1/$intervalSeconds,scale=$thumbWidth:$thumbHeight',
          '-q:v', '5', // JPEG quality (2=best, 31=worst)
          p.join(dir, 'thumb_%05d.jpg'),
        ],
      );
      _liveProcesses.add(proc);

      // Capture stderr (small — loglevel=error keeps it short) so we can
      // report a real reason on failure. Drain stdout unconditionally.
      unawaited(proc.stdout.drain<void>());
      final stderrFuture = proc.stderr
          .transform(utf8.decoder)
          .join()
          .catchError((_) => ''); // ignore decode errors, we only want a hint

      // Hard timeout purely as a dead-man's-switch for pathological cases
      // (zero-byte / DRM-locked files where ffmpeg hangs on demuxer open).
      // Set VERY generously (2 h) because a legitimately slow 4K Blu-ray
      // rip on a slow external disk + heavy codec can take tens of
      // minutes. A truly hung ffmpeg almost always stalls in the opening
      // seconds — it never stalls mid-progress — so this only fires on
      // the pathological case, never on "just slow".
      final exitCode = await proc.exitCode.timeout(
        const Duration(hours: 2),
        onTimeout: () {
          proc?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      if (exitCode == 0) {
        // Write done marker with explicit flush so a process kill /
        // power loss immediately after ffmpeg exit doesn't leave the
        // marker in an OS buffer but the jpgs already durable — on
        // next launch `hasThumbnails` would return false and we'd
        // regenerate, which is the ANNOYING-BUT-SAFE direction. The
        // reverse (marker flushed, jpgs not yet fully written) would
        // silently skip generation and leave the user with missing
        // previews they'd never see a retry for.
        //
        // `flush: true` forces fsync on the marker file. We can't
        // fsync the jpgs from Dart without re-opening every file,
        // but ffmpeg uses buffered writes that on a normal exit are
        // flushed to disk before it returns exit-code 0 — so by the
        // time we're writing the marker, jpgs are already durable on
        // every OS we care about.
        await File(p.join(dir, '.done'))
            .writeAsString('1', flush: true);
        lastErrorMessage = null;
        return true;
      }
      // Non-zero exit → capture stderr for the user-facing error.
      final stderr = (await stderrFuture).trim();
      final firstLine = stderr.split('\n').firstWhere(
            (l) => l.trim().isNotEmpty,
            orElse: () => 'ffmpeg beendet mit Code $exitCode',
          );
      lastErrorMessage = firstLine.length > 240
          ? '${firstLine.substring(0, 240)}…'
          : firstLine;
      return false;
    } catch (e) {
      // Best-effort kill in case Process.start succeeded but something else blew up.
      try {
        proc?.kill(ProcessSignal.sigkill);
      } catch (_) {/* no-op */}
      lastErrorMessage = 'Start/Lauf von FFmpeg fehlgeschlagen: $e';
      return false;
    } finally {
      if (proc != null) _liveProcesses.remove(proc);
    }
  }

  /// Clears all cached thumbnails.
  Future<void> clearCache() async {
    await initialize();
    final dir = Directory(_cacheDir!);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }
  }

  /// Total size of the thumbnail cache on disk, in bytes.
  Future<int> getCacheSize() async {
    await initialize();
    final dir = Directory(_cacheDir!);
    if (!await dir.exists()) return 0;
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // Skip files we can't stat
          }
        }
      }
    } catch (_) {
      // Ignore listing errors
    }
    return total;
  }

  /// Deletes thumbnail folders that no longer correspond to any video in the
  /// given set of current video paths. Returns the number of folders removed.
  ///
  /// Safety: if [currentVideoPaths] is empty we do NOTHING. An empty set can
  /// mean "all videos were genuinely deleted" but it can also mean "scan
  /// returned no items because the external drive vanished for a millisecond
  /// during listing". The second case would nuke the entire cache, so we
  /// prefer to keep orphans over risking that.
  Future<int> cleanupOrphaned(
    Set<String> currentVideoPaths, {
    /// Extra paths whose cache folders should survive cleanup even if
    /// they are absent from [currentVideoPaths]. Populated by the
    /// library provider from:
    ///  - the global "Cache für entfernte Medien behalten" setting
    ///    (all historic paths) or
    ///  - the per-item keepCache flags (just flagged items' paths).
    Set<String> sparePaths = const {},
  }) async {
    await initialize();
    if (currentVideoPaths.isEmpty && sparePaths.isEmpty) return 0;
    final dir = Directory(_cacheDir!);
    if (!await dir.exists()) return 0;

    // Build the set of folder names that are still valid.
    final validNames = <String>{
      for (final path in currentVideoPaths) p.basename(_videoCacheDir(path)),
      for (final path in sparePaths) p.basename(_videoCacheDir(path)),
    };

    int removed = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (validNames.contains(name)) continue;
      try {
        await entity.delete(recursive: true);
        removed++;
      } catch (_) {
        // Ignore individual failures (file locked, etc.)
      }
    }
    return removed;
  }

  /// Deletes the thumbnail folder for a specific video path. Used by
  /// the per-item reset tree in settings and by the change-detection
  /// dialog when the user chooses "Cache neu erstellen" for a
  /// modified file. Silent no-op if the folder doesn't exist.
  Future<void> clearCacheForPath(String videoPath) async {
    await initialize();
    final dir = Directory(_videoCacheDir(videoPath));
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* best-effort — file locked, etc. */}
  }

  /// Bulk version of [clearCacheForPath]. Used for series / season
  /// resets where the caller has every episode path ready. Iterates
  /// sequentially to keep AV scanners from choking on dozens of
  /// concurrent deletes on Windows.
  Future<void> clearCacheForPaths(Iterable<String> videoPaths) async {
    for (final p in videoPaths) {
      await clearCacheForPath(p);
    }
  }
}
