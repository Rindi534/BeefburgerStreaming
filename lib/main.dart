import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'models/media_metadata.dart';
import 'models/watch_progress.dart';
import 'app.dart';

/// Opens a Hive box, and if the box file is corrupted (e.g. after a crash or
/// disk error) deletes it and opens a fresh one. The alternative is the app
/// refusing to start, which is much worse than losing preferences.
Future<Box<T>> _openBoxSafely<T>(String name) async {
  try {
    return await Hive.openBox<T>(name);
  } catch (_) {
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {/* best-effort */}
    return await Hive.openBox<T>(name);
  }
}

/// Simple lock-file-based single-instance guard. If another instance is
/// already running (holding the lock), we exit quietly instead of starting a
/// second copy that would race on the same Hive box. Lock is auto-released
/// on process exit because the OS closes the file handle.
Future<bool> _acquireSingleInstanceLock() async {
  if (!Platform.isWindows) return true; // only needed on desktop Windows
  try {
    final dir = await getApplicationSupportDirectory();
    final lockFile = File(p.join(dir.path, 'app.lock'));
    // Opening the file with exclusive-write is the closest portable equivalent
    // to a real OS lock; a second instance will fail with FileSystemException.
    final raf = await lockFile.open(mode: FileMode.write);
    // Keep the handle alive for the lifetime of the process by stashing it.
    _lockHandle = raf;
    return true;
  } catch (_) {
    return false;
  }
}

// Kept alive intentionally — the OS releases the file handle on exit,
// which is what signals "this instance is gone" to the next launch.
// ignore: unused_field
RandomAccessFile? _lockHandle;

/// iOS-only: moves any existing Hive files from the app's Documents
/// directory to the Support directory [dest]. No-op if no files need
/// moving (fresh install or already migrated).
///
/// The three box names below are hard-coded to match what `main()`
/// opens — both the data (`.hive`) and lock (`.lock`) files. We fail
/// silently per-file: losing a `.lock` sidecar is harmless (Hive
/// recreates it), and losing a data file falls through to the usual
/// corruption-recovery path in `_openBoxSafely`.
Future<void> _migrateHiveFromDocumentsIfNeeded(String dest) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    // Don't copy onto ourselves — older Flutter versions or weirdly
    // symlinked sandboxes could theoretically have Documents == Support.
    if (p.equals(docs.path, dest)) return;

    const boxes = ['settings', 'watch_progress', 'media_history'];
    for (final name in boxes) {
      for (final ext in ['hive', 'lock']) {
        final src = File(p.join(docs.path, '$name.$ext'));
        final target = File(p.join(dest, '$name.$ext'));
        if (await src.exists() && !await target.exists()) {
          try {
            await src.rename(target.path);
          } catch (_) {
            // Cross-filesystem? Fall back to copy + delete.
            try {
              await src.copy(target.path);
              await src.delete();
            } catch (_) {/* give up silently, see doc above */}
          }
        }
      }
    }
  } catch (_) {
    // Any top-level failure is non-fatal — a fresh Hive in Support is
    // the correct fallback.
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // iOS: App global auf Portrait locken. Home, Detail-Screen und
  // Einstellungen sind nie für Landscape designed — ohne diesen Lock
  // kippt das Layout um sobald ein iPhone mal zur Seite gedreht wird.
  // Der Video-Player (IOSVLCPlayerScreen / IOSPlayerScreen) überschreibt
  // das in seinem initState temporär zu Landscape und stellt beim
  // Schließen die Portrait-Lock wieder her.
  if (Platform.isIOS) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  // Initialize window manager for desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.setMinimumSize(const Size(800, 500));
  }

  // Single-instance guard: if another BeefburgerStreaming is already running,
  // bring it to the front (best-effort) and exit quietly. Two instances would
  // fight over the same Hive boxes which can corrupt them.
  final gotLock = await _acquireSingleInstanceLock();
  if (!gotLock) {
    try {
      await windowManager.focus();
    } catch (_) {/* no-op */}
    exit(0);
  }

  // Initialize Hive — with corruption recovery so a bad shutdown can't brick
  // the app on next start.
  //
  // On iOS Hive.initFlutter() defaults to the app's Documents directory,
  // which is the SAME place our iOS folder picker hands users as their
  // "media folder" (Documents is the only writable spot visible via the
  // Files app on iPhone/iPad). The result: users dropping media into
  // their Files folder saw `settings.hive`, `watch_progress.hive`,
  // `*.lock` etc. littered alongside their videos.
  //
  // Fix: point Hive at the app's *Support* directory on iOS. That
  // directory is in the same sandbox, persistent, automatically
  // backed up by iCloud, but invisible in the Files app — exactly
  // what we want for internal state.
  //
  // One-time migration: if any .hive files exist in Documents from
  // earlier builds, move them over so the user doesn't lose watch
  // progress on upgrade.
  if (Platform.isIOS) {
    final supportDir = await getApplicationSupportDirectory();
    await _migrateHiveFromDocumentsIfNeeded(supportDir.path);
    Hive.init(supportDir.path);
  } else if (Platform.isWindows) {
    // Windows: dieselbe Logik wie iOS. `Hive.initFlutter()` ruft
    // intern `getApplicationDocumentsDirectory()` auf — auf Windows
    // ist das `C:\Users\<user>\Documents`, also der ganz normale
    // sichtbare Dokumente-Ordner. Da landeten dann
    // `settings.hive`, `watch_progress.hive`, `media_history.hive`
    // (+ .lock-Sidecars) direkt zwischen den User-Files. Schlecht
    // aufgehoben.
    //
    // Korrekt: `getApplicationSupportDirectory()` →
    // `C:\Users\<user>\AppData\Roaming\<company>\<product>\` —
    // unsichtbar im normalen Dateimanager-Workflow, aber persistent
    // und vom OS für genau diesen Zweck (App-State) vorgesehen.
    //
    // Migration: existierende .hive/.lock-Files aus Documents werden
    // einmal nach Support verschoben, damit Watch-Progress &
    // Settings beim Update nicht verloren gehen.
    final supportDir = await getApplicationSupportDirectory();
    await _migrateHiveFromDocumentsIfNeeded(supportDir.path);
    Hive.init(supportDir.path);
  } else {
    await Hive.initFlutter();
  }
  Hive.registerAdapter(WatchProgressAdapter());
  Hive.registerAdapter(MediaMetadataAdapter());
  await _openBoxSafely<dynamic>('settings');
  await _openBoxSafely<WatchProgress>('watch_progress');
  await _openBoxSafely<MediaMetadata>('media_history');

  runApp(
    const ProviderScope(
      child: HomeStreamingApp(),
    ),
  );
}
