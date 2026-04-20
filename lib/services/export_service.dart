import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'thumbnail_service.dart';

/// Handles exporting stills (PNG) and clips (MP4) from the video player to a
/// user-chosen folder. Clips are produced via FFmpeg (same binary used for
/// seekbar thumbnails), re-encoded so cuts are frame-accurate at any position
/// (stream-copy would only cut at keyframes, which is surprising UX).
class ExportService {
  ExportService._();
  static final ExportService instance = ExportService._();

  /// Writes PNG bytes to `<exportFolder>/<name>.png`. If the file already
  /// exists a numeric suffix `(2)`, `(3)` … is appended so a fast double-tap
  /// never overwrites a previous screenshot.
  ///
  /// Returns the final written path on success, or a human-readable error
  /// message on failure (disk full, permission denied, folder vanished).
  Future<ExportResult> saveScreenshot({
    required Uint8List pngBytes,
    required String exportFolder,
    required String name,
  }) async {
    try {
      if (!await Directory(exportFolder).exists()) {
        return ExportResult.error(
          'Export-Ordner nicht gefunden:\n$exportFolder\n\n'
          'Bitte in den Einstellungen einen gültigen Ordner wählen.',
        );
      }
      final target = await _resolveUniquePath(exportFolder, name, 'png');
      await File(target).writeAsBytes(pngBytes, flush: true);
      return ExportResult.success(target);
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode ?? 0;
      if (code == 112 || code == 39) {
        return ExportResult.error(
            'Festplatte voll — Foto konnte nicht gespeichert werden.');
      }
      return ExportResult.error('Speichern fehlgeschlagen: ${e.message}');
    } catch (e) {
      return ExportResult.error('Speichern fehlgeschlagen: $e');
    }
  }

  /// Cuts `[start, end]` from [sourceVideoPath] and writes it as an MP4 with
  /// audio into the export folder.
  ///
  /// Re-encodes on the fly (libx264 + aac) — slow-ish for long clips but
  /// produces a clip that starts *exactly* on the first marker, not on the
  /// nearest preceding keyframe. `-preset veryfast` keeps wall-clock time
  /// reasonable; typical 30-second clip on a mid-range desktop = a few
  /// seconds to export.
  ///
  /// Stderr is drained so full pipes can't deadlock ffmpeg.
  Future<ExportResult> exportClip({
    required String sourceVideoPath,
    required Duration start,
    required Duration end,
    required String exportFolder,
    required String name,
  }) async {
    if (end <= start) {
      return ExportResult.error(
          'Endpunkt muss nach dem Startpunkt liegen.');
    }
    if (!await File(sourceVideoPath).exists()) {
      return ExportResult.error(
          'Quelldatei nicht gefunden — wurde sie verschoben?');
    }
    if (!await Directory(exportFolder).exists()) {
      return ExportResult.error(
        'Export-Ordner nicht gefunden:\n$exportFolder\n\n'
        'Bitte in den Einstellungen einen gültigen Ordner wählen.',
      );
    }

    final ffmpeg = await ThumbnailService.instance.findFFmpeg();
    if (ffmpeg == null) {
      return ExportResult.error(
        'FFmpeg wurde nicht gefunden — Video-Clips können nicht erstellt '
        'werden. Siehe "Ordner-Konvention" / README für Installation.',
      );
    }

    final target = await _resolveUniquePath(exportFolder, name, 'mp4');
    final startSec = start.inMilliseconds / 1000.0;
    final durationSec = (end - start).inMilliseconds / 1000.0;

    // Argument order matters for accuracy:
    //   -ss BEFORE -i = fast seek (rough, keyframe-aligned)
    //   -ss AFTER  -i = accurate seek (demuxes from 0, slow but exact)
    // We do BOTH: a fast seek to near the start, then an accurate seek
    // inside, so long files don't decode from scratch but the first frame
    // is still exactly right. This is the ffmpeg-recommended pattern for
    // "fast-and-accurate" cutting.
    final fastSeek = (startSec - 5).clamp(0.0, double.infinity);
    final accurateSeek = startSec - fastSeek;

    Process? proc;
    try {
      proc = await Process.start(ffmpeg, [
        '-loglevel', 'error',
        '-y',
        '-ss', fastSeek.toStringAsFixed(3),
        '-i', sourceVideoPath,
        '-ss', accurateSeek.toStringAsFixed(3),
        '-t', durationSec.toStringAsFixed(3),
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '20',
        '-c:a', 'aac',
        '-b:a', '192k',
        // Ensure MP4 is playable before the export finishes writing (for
        // "Im Export-Ordner anzeigen" peeks) by moving the moov atom to
        // the start. Cheap for short clips.
        '-movflags', '+faststart',
        target,
      ]);

      final stderrBuf = StringBuffer();
      proc.stderr.transform(const SystemEncoding().decoder).listen(
            stderrBuf.write,
            onError: (_) {/* ignore */},
          );
      unawaited(proc.stdout.drain<void>());

      // 30-minute ceiling: even a long clip on a slow disk + modest CPU
      // should finish in single-digit minutes. If it hasn't in 30 min,
      // something's wrong (file corrupted mid-export, disk stalled).
      final exitCode = await proc.exitCode.timeout(
        const Duration(minutes: 30),
        onTimeout: () {
          proc?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      if (exitCode == 0 && await File(target).exists()) {
        return ExportResult.success(target);
      }
      // Best-effort cleanup of partial output.
      try {
        final f = File(target);
        if (await f.exists()) await f.delete();
      } catch (_) {/* no-op */}
      final err = stderrBuf.toString().trim();
      return ExportResult.error(
        err.isEmpty
            ? 'Clip-Export fehlgeschlagen (FFmpeg exit $exitCode).'
            : 'Clip-Export fehlgeschlagen:\n$err',
      );
    } catch (e) {
      try {
        proc?.kill(ProcessSignal.sigkill);
      } catch (_) {/* no-op */}
      return ExportResult.error('Clip-Export fehlgeschlagen: $e');
    }
  }

  /// Sanitises a user-provided base name into something safe for Windows
  /// filesystems. Strips path separators and the Win32 reserved chars
  /// `<>:"/\|?*` plus control chars. Empty result → `export`.
  String sanitizeBaseName(String input) {
    var s = input.trim();
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    // Trim trailing dots/spaces (also reserved on Windows).
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) return 'export';
    // Cap length — path + name + extension must fit MAX_PATH margins.
    if (s.length > 120) s = s.substring(0, 120);
    return s;
  }

  /// Produces a filename that doesn't collide with an existing file in
  /// [folder]. If `name.ext` is free, returns that; otherwise tries
  /// `name (2).ext`, `name (3).ext`, ... up to a sane limit.
  Future<String> _resolveUniquePath(
      String folder, String name, String ext) async {
    final base = sanitizeBaseName(name);
    final first = p.join(folder, '$base.$ext');
    if (!await File(first).exists()) return first;
    for (int i = 2; i < 1000; i++) {
      final candidate = p.join(folder, '$base ($i).$ext');
      if (!await File(candidate).exists()) return candidate;
    }
    // Pathological fallback — 1000 copies of the same name. Stamp a timestamp.
    return p.join(
        folder, '$base-${DateTime.now().millisecondsSinceEpoch}.$ext');
  }
}

/// Result of an export operation. Either a written file path on success or a
/// user-facing error message to show in a snackbar / dialog.
class ExportResult {
  final String? path;
  final String? error;
  const ExportResult._(this.path, this.error);
  factory ExportResult.success(String path) => ExportResult._(path, null);
  factory ExportResult.error(String msg) => ExportResult._(null, msg);
  bool get isSuccess => path != null;
}
