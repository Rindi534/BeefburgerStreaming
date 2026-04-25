// Rotating file logger for crash/diagnostic capture.
//
// Why:
//   Flutter desktop apps don't write any crash trace by default.
//   When the user double-clicks the .exe and something blows up, we get
//   nothing — no stderr (no console attached), and Windows Error
//   Reporting at best leaves an opaque minidump in %LOCALAPPDATA%\
//   CrashDumps\ that we can't read without symbols. This service
//   captures three classes of failure into a plain-text rotating log
//   file the user can mail us when something goes wrong:
//
//     1. FlutterError.onError       — synchronous framework errors
//                                     (build, layout, paint).
//     2. PlatformDispatcher.onError — uncaught async errors that
//                                     escape Flutter's zone.
//     3. runZonedGuarded            — anything else that bubbles up
//                                     from the top-level zone.
//
// Where:
//   getApplicationSupportDirectory() / 'logs' / 'app.log'.
//   On Windows that's %APPDATA%\Roaming\<company>\<product>\logs\
//   — the same hidden-from-the-user spot we just moved Hive into. NOT
//   in Documents, NOT in the media folder.
//
// Size cap (the "darf nicht auf Gigabyte anschwellen" requirement):
//   Each file is capped at 1 MiB. When the current `app.log` reaches
//   that size we rotate: delete `app.1.log` if present, rename
//   `app.log` → `app.1.log`, then start a fresh `app.log`. Total
//   on-disk footprint stays at ≤ 2 MiB — enough for ~3-7 sessions
//   worth of warnings/errors, way too small to ever notice on disk.
//
// Failure mode:
//   Every public method is "best effort". If init fails (perms,
//   read-only volume, …) we silently degrade to console-only logging
//   and the rest of the app runs unaffected. We must NEVER throw out
//   of the logger, because that would make every error path a
//   crash-on-crash.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LogService {
  /// Per-file size cap. 1 MiB is more than enough for hours of session
  /// at our typical write rate (mostly errors + the occasional info).
  static const int _maxFileBytes = 1024 * 1024;

  static const String _currentName = 'app.log';
  static const String _rotatedName = 'app.1.log';

  static IOSink? _sink;
  static int _currentSize = 0;
  static String? _logDir;
  static bool _initialized = false;

  /// Resolves the log directory and opens `app.log` in append mode.
  /// Idempotent — calling twice is a no-op. Safe to invoke before
  /// runApp(); failures are swallowed.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'logs'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logDir = dir.path;

      final cur = File(p.join(dir.path, _currentName));
      if (await cur.exists()) {
        _currentSize = await cur.length();
        // Already over cap from a previous session that crashed before
        // it could rotate? Rotate now, before we open the sink, so we
        // don't blow past the cap on this session's first write.
        if (_currentSize >= _maxFileBytes) {
          await _rotate();
        }
      }
      _sink = File(p.join(dir.path, _currentName))
          .openWrite(mode: FileMode.writeOnlyAppend);
      _initialized = true;

      // Session header — useful when reading multiple sessions glued
      // together in one file. Includes the platform and OS version so
      // remote bug reports tell us right away which build was used.
      _writeLine(
        '---- session start ${DateTime.now().toIso8601String()} '
        'platform=${Platform.operatingSystem} '
        'osVersion=${Platform.operatingSystemVersion} ----',
      );
    } catch (_) {
      // Fall through: _initialized stays false, log() becomes a no-op
      // at file level (still goes to debugPrint in debug builds).
    }
  }

  /// Generic info-level log entry.
  static void info(String message) =>
      _emit('INFO', message, error: null, stack: null);

  /// Warning — recoverable problem worth recording.
  static void warn(String message, {Object? error, StackTrace? stack}) =>
      _emit('WARN', message, error: error, stack: stack);

  /// Error — something failed; include error and stack if you have them.
  static void error(String message, {Object? error, StackTrace? stack}) =>
      _emit('ERROR', message, error: error, stack: stack);

  /// Hard crash entry — used by the global error handlers in main.dart.
  /// Keeps a separate level so a crash is visually obvious in the file.
  static void crash(String message, {Object? error, StackTrace? stack}) =>
      _emit('CRASH', message, error: error, stack: stack);

  static void _emit(String level, String message,
      {Object? error, StackTrace? stack}) {
    final ts = DateTime.now().toIso8601String();
    final buf = StringBuffer()
      ..write(ts)
      ..write(' [')
      ..write(level)
      ..write('] ')
      ..write(message);
    if (error != null) {
      buf
        ..write(' | error=')
        ..write(error.toString());
    }
    if (stack != null) {
      buf
        ..write('\n')
        ..write(stack.toString());
    }
    final line = buf.toString();

    // In debug builds also surface to console; in release builds
    // there's nowhere to print to anyway (no attached terminal on a
    // double-clicked .exe).
    if (kDebugMode) debugPrint(line);

    _writeLine(line);
  }

  static void _writeLine(String line) {
    final sink = _sink;
    if (sink == null) return;
    try {
      final bytes = utf8.encode('$line\n');
      sink.add(bytes);
      _currentSize += bytes.length;
      if (_currentSize >= _maxFileBytes) {
        // Don't await — rotating asynchronously is fine; in the worst
        // case we overshoot the cap by one buffered batch, then the
        // next call rotates. Awaiting here would force every error
        // log into a slow path which is bad when something is already
        // on fire.
        unawaited(_rotate());
      }
    } catch (_) {
      // Disk full / file gone / permission revoked mid-session — drop
      // the line silently. The alternative is throwing from inside an
      // error handler, which is worse than losing one log entry.
    }
  }

  static Future<void> _rotate() async {
    final dir = _logDir;
    if (dir == null) return;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {/* keep going */}
    _sink = null;
    try {
      final cur = File(p.join(dir, _currentName));
      final rotated = File(p.join(dir, _rotatedName));
      if (await rotated.exists()) {
        await rotated.delete();
      }
      if (await cur.exists()) {
        await cur.rename(rotated.path);
      }
      _currentSize = 0;
      _sink = File(p.join(dir, _currentName))
          .openWrite(mode: FileMode.writeOnlyAppend);
    } catch (_) {
      // Couldn't rotate — leave _sink null so subsequent writes are
      // dropped instead of growing the file forever. Next session's
      // init() will retry.
    }
  }

  /// Best-effort flush — call at clean shutdown if you can.
  static Future<void> shutdown() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _initialized = false;
  }
}
