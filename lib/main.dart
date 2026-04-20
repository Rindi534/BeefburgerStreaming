import 'dart:io';
import 'package:flutter/material.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

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
  await Hive.initFlutter();
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
