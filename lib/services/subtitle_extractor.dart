// SubtitleExtractor — extrahiert eingebettete Untertitel-Streams
// aus einer Video-Datei (typisch .mkv mit embedded SRT/ASS/SSA
// tracks) als externe .srt-Dateien in einen Cache-Ordner.
//
// Hintergrund: libvlcs `vmem`-Output (memory output via
// video_set_callbacks) compositet SPU NICHT in unseren Frame-Buffer.
// Statt das Limit zu umgehen, holen wir die Subs einfach selbst
// aus der Datei mit ffmpeg-kit, cachen sie als .srt und rendern
// sie über SubtitleOverlay (Dart-side Text-Rendering über die
// VLC-DisplayLayer).
//
// Cache-Schema:
//   <App-Support>/extracted_subs/<file-hash>/
//     index.json    — Liste {trackIndex, language, srtPath}
//     sub_0.srt
//     sub_1.srt
//     ...
//
// Cache-Key ist Hash von (filePath + filesize + mtime) — damit
// derselbe File nur einmal extrahiert wird, aber bei Datei-Änderung
// re-extrahiert wird. Bei großen MKVs dauert das 5-15s.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ExtractedSubtitleTrack {
  final int sourceIndex; // 0-basierter Index unter den Sub-Streams
  final String language; // ISO 639-2/B (zb "ger", "eng") — leer wenn unbekannt
  final String? title; // Optional aus dem Container-Metadata
  final String srtPath; // Pfad zur extrahierten .srt
  final String displayName; // Hübsche Anzeige (zb "Deutsch · Track 0")

  const ExtractedSubtitleTrack({
    required this.sourceIndex,
    required this.language,
    required this.title,
    required this.srtPath,
    required this.displayName,
  });

  Map<String, dynamic> toJson() => {
        'sourceIndex': sourceIndex,
        'language': language,
        'title': title,
        'srtPath': srtPath,
        'displayName': displayName,
      };

  factory ExtractedSubtitleTrack.fromJson(Map<String, dynamic> j) =>
      ExtractedSubtitleTrack(
        sourceIndex: j['sourceIndex'] as int,
        language: j['language'] as String? ?? '',
        title: j['title'] as String?,
        srtPath: j['srtPath'] as String,
        displayName: j['displayName'] as String,
      );
}

class SubtitleExtractor {
  /// Hauptentry. Liefert die Liste der bereits-cached oder frisch-
  /// extrahierten Subtitle-Tracks. Bei laufender Wiedergabe blockt
  /// das nicht — die Extraction läuft auf einem separaten Isolate
  /// (ffmpeg-kit nutzt intern Background-Threads). Während der
  /// Extraction kann der User schon das Video schauen, die
  /// Untertitel poppen rein wenn die Extraction fertig ist.
  static Future<List<ExtractedSubtitleTrack>> extractTracks(
      String videoPath) async {
    try {
      final cacheDir = await _cacheDirFor(videoPath);
      final indexFile = File(p.join(cacheDir.path, 'index.json'));

      // Cache-Hit?
      if (await indexFile.exists()) {
        try {
          final raw = await indexFile.readAsString();
          final list = (jsonDecode(raw) as List)
              .map((e) => ExtractedSubtitleTrack.fromJson(
                  e as Map<String, dynamic>))
              .toList();
          // Validate: alle .srt-Files existieren noch?
          final allValid = await Future.wait(
              list.map((t) => File(t.srtPath).exists()));
          if (allValid.every((b) => b)) {
            return list;
          }
        } catch (_) {
          // Cache korrupt — fall through und neu extrahieren.
        }
      }

      // Cache-Miss: ffprobe → finde Sub-Streams
      final streams = await _probeSubStreams(videoPath);
      if (streams.isEmpty) {
        // Keine Subs im File. Cache das Result als leere Liste
        // damit wir nicht jedes Mal probent.
        await cacheDir.create(recursive: true);
        await indexFile.writeAsString('[]');
        return const [];
      }

      // Extrahiere alle Streams einzeln. Wir extrahieren parallel
      // wäre theoretisch schneller aber verkompliziert die
      // Fehlerbehandlung — sequenziell ist robust und für 99% der
      // Use-Cases (1-3 Sub-Tracks) schnell genug.
      await cacheDir.create(recursive: true);
      final extracted = <ExtractedSubtitleTrack>[];
      for (int i = 0; i < streams.length; i++) {
        final stream = streams[i];
        final outPath = p.join(cacheDir.path, 'sub_$i.srt');
        final ok = await _extractStream(
          videoPath: videoPath,
          subStreamIndex: i, // 0-basiert unter den sub-streams
          outputPath: outPath,
        );
        if (!ok) continue;

        final lang = stream['language'] as String? ?? '';
        final title = stream['title'] as String?;
        extracted.add(ExtractedSubtitleTrack(
          sourceIndex: i,
          language: lang,
          title: title,
          srtPath: outPath,
          displayName: _prettyName(language: lang, title: title, fallbackIndex: i),
        ));
      }

      // Index speichern für Cache-Reuse.
      await indexFile.writeAsString(
          jsonEncode(extracted.map((e) => e.toJson()).toList()));
      return extracted;
    } catch (e) {
      // Sub-Extraction ist Best-Effort — wenn was schiefgeht,
      // läuft das Video weiter, nur ohne Subs.
      // ignore: avoid_print
      print('[SubtitleExtractor] failed: $e');
      return const [];
    }
  }

  // ─── Internals ────────────────────────────────────────────────

  static Future<Directory> _cacheDirFor(String videoPath) async {
    final base = await getApplicationSupportDirectory();
    final f = File(videoPath);
    final stat = await f.stat();
    // Cache-Key: Pfad + size + mtime — kollidiert nicht über
    // Files mit gleichem Namen, wird invalidiert wenn Datei
    // geändert wurde.
    final key = '${videoPath}_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
    final hash = key.hashCode.toUnsigned(32).toRadixString(16);
    return Directory(p.join(base.path, 'extracted_subs', hash));
  }

  /// ffprobe ausführen und JSON mit allen subtitle-streams parsen.
  /// Returns Liste von {language, title, codec_name} pro Stream.
  static Future<List<Map<String, dynamic>>> _probeSubStreams(
      String videoPath) async {
    final escaped = videoPath.replaceAll('"', '\\"');
    final cmd =
        '-v error -select_streams s -show_streams -print_format json "$escaped"';
    final session = await FFprobeKit.execute(cmd);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) return const [];
    final output = await session.getOutput() ?? '';
    if (output.isEmpty) return const [];
    try {
      final parsed = jsonDecode(output) as Map<String, dynamic>;
      final streams = (parsed['streams'] as List?) ?? const [];
      return streams.map((s) {
        final tags = (s as Map<String, dynamic>)['tags']
                as Map<String, dynamic>? ??
            const {};
        return {
          'language': tags['language'] ?? '',
          'title': tags['title'],
          'codec_name': s['codec_name'] ?? '',
        };
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Extrahiert einen einzelnen Sub-Stream als .srt. ffmpeg's
  /// `-c:s srt` konvertiert ASS/SSA/MOV-Subs zu SRT (text-based).
  /// PGS/Bitmap-Subs können nicht zu SRT konvertiert werden — die
  /// schlagen fehl, wir überspringen sie still.
  static Future<bool> _extractStream({
    required String videoPath,
    required int subStreamIndex,
    required String outputPath,
  }) async {
    final escapedIn = videoPath.replaceAll('"', '\\"');
    final escapedOut = outputPath.replaceAll('"', '\\"');
    // -y: überschreibe wenn schon existiert
    // -map 0:s:N: nimm den N-ten Subtitle-Stream
    // -c:s srt: zwinge SRT-Output (text)
    final cmd =
        '-y -i "$escapedIn" -map 0:s:$subStreamIndex -c:s srt "$escapedOut"';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) return false;
    // Sicherheitscheck: file existiert + hat content
    final f = File(outputPath);
    if (!await f.exists()) return false;
    final size = await f.length();
    return size > 0;
  }

  static String _prettyName({
    required String language,
    String? title,
    required int fallbackIndex,
  }) {
    final langName = _languageName(language);
    final parts = <String>[];
    if (langName != null) parts.add(langName);
    if (title != null && title.isNotEmpty) parts.add(title);
    if (parts.isEmpty) parts.add('Track $fallbackIndex');
    return parts.join(' · ');
  }

  /// Mapping ISO-639 → vollständiger Sprachname (deutsch).
  /// Nur die häufigsten — alles andere fällt auf den Code zurück.
  static String? _languageName(String code) {
    switch (code.toLowerCase()) {
      case 'ger':
      case 'deu':
        return 'Deutsch';
      case 'eng':
        return 'Englisch';
      case 'fre':
      case 'fra':
        return 'Französisch';
      case 'spa':
        return 'Spanisch';
      case 'ita':
        return 'Italienisch';
      case 'jpn':
        return 'Japanisch';
      case 'rus':
        return 'Russisch';
      case 'pol':
        return 'Polnisch';
      case 'tur':
        return 'Türkisch';
      case 'nld':
      case 'dut':
        return 'Niederländisch';
      case 'por':
        return 'Portugiesisch';
      case 'chi':
      case 'zho':
        return 'Chinesisch';
      case 'kor':
        return 'Koreanisch';
      case 'ara':
        return 'Arabisch';
      case '':
      case 'und':
        return null;
      default:
        return code.toUpperCase();
    }
  }
}
