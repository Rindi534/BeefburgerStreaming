// SRT-Parser für Subtitle-Files. Unterstützt:
//   - Standard-SRT (00:00:00,000 --> 00:00:00,000)
//   - SRT mit Punkten statt Komma als Millisekunden-Trenner
//   - HTML-Tags (<i>, <b>, <font>, ...) — werden gestrippt
//   - UTF-8 mit BOM oder Latin-1 als Encoding-Fallback
//
// Wird vom SubtitleOverlay-Widget genutzt um Subs Dart-side zu
// rendern — Workaround für libvlcs vmem-Output das SPU nicht
// in unseren Frame-Buffer compositet.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SubtitleEntry {
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleEntry({
    required this.start,
    required this.end,
    required this.text,
  });
}

class SrtParser {
  /// Lädt und parst eine .srt-Datei vom Filesystem. Bei
  /// Encoding-Fehlern (häufig bei deutschen Subs in Latin-1)
  /// fallen wir auf latin1 zurück.
  static Future<List<SubtitleEntry>> parseFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return const [];
      final bytes = await file.readAsBytes();
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        content = latin1.decode(bytes);
      }
      return parseString(content);
    } catch (_) {
      return const [];
    }
  }

  /// Parst SRT-Content aus einem String. Robust gegen kleinere
  /// Format-Abweichungen (BOM, CRLF/LF, Punkt vs. Komma).
  static List<SubtitleEntry> parseString(String content) {
    if (content.startsWith('﻿')) {
      content = content.substring(1);
    }

    final entries = <SubtitleEntry>[];
    final blocks = content.split(RegExp(r'\r?\n\r?\n'));
    final timingRe = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*'
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})',
    );

    for (final block in blocks) {
      final raw = block.trim();
      if (raw.isEmpty) continue;
      final lines = raw.split(RegExp(r'\r?\n'));
      if (lines.length < 2) continue;

      // Timing-Zeile finden (typisch Zeile 0 oder 1, je nach
      // ob die optionale Index-Zeile dabei ist).
      int timingIdx = -1;
      Match? m;
      for (int i = 0; i < lines.length && i < 3; i++) {
        final candidate = timingRe.firstMatch(lines[i]);
        if (candidate != null) {
          timingIdx = i;
          m = candidate;
          break;
        }
      }
      if (m == null) continue;

      final start = Duration(
        hours: int.parse(m.group(1)!),
        minutes: int.parse(m.group(2)!),
        seconds: int.parse(m.group(3)!),
        milliseconds: int.parse(m.group(4)!),
      );
      final end = Duration(
        hours: int.parse(m.group(5)!),
        minutes: int.parse(m.group(6)!),
        seconds: int.parse(m.group(7)!),
        milliseconds: int.parse(m.group(8)!),
      );

      final textLines = lines.sublist(timingIdx + 1);
      final text = textLines
          .map((l) => l.replaceAll(RegExp(r'<[^>]+>'), '').trim())
          .where((l) => l.isNotEmpty)
          .join('\n');

      if (text.isEmpty) continue;
      entries.add(SubtitleEntry(start: start, end: end, text: text));
    }

    entries.sort((a, b) => a.start.compareTo(b.start));
    return entries;
  }

  /// Findet den/die Sub-Eintrag der zur aktuellen Position passt.
  /// Linear scan reicht — selbst Filme haben selten >2000 Einträge,
  /// 2000 Vergleiche pro frame sind nichts.
  static String? findActiveText(
      List<SubtitleEntry> entries, Duration position) {
    for (final e in entries) {
      if (position >= e.start && position <= e.end) {
        return e.text;
      }
    }
    return null;
  }
}
