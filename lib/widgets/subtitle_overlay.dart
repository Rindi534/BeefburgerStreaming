// Dart-side Subtitle-Renderer. Wird über die VLC-DisplayLayer
// gelegt und zeigt den aktiven Subtitle-Text basierend auf der
// aktuellen Wiedergabe-Position.
//
// Hintergrund: libvlcs `memory output` (vmem) compositet keine
// SPU in unseren Frame-Buffer. Statt das in libvlc zu fixen
// (Architektur-Limitation in MobileVLCKit) rendern wir die Subs
// als Flutter-Widget über die Layer.

import 'dart:async';
import 'package:flutter/material.dart';
import '../services/srt_parser.dart';

class SubtitleOverlay extends StatefulWidget {
  final List<SubtitleEntry> entries;
  final Stream<Duration> positionStream;
  final Duration initialPosition;

  const SubtitleOverlay({
    super.key,
    required this.entries,
    required this.positionStream,
    this.initialPosition = Duration.zero,
  });

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  Duration _position = Duration.zero;
  StreamSubscription<Duration>? _sub;
  String? _currentText;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
    _updateText();
    _sub = widget.positionStream.listen((pos) {
      if (!mounted) return;
      _position = pos;
      _updateText();
    });
  }

  @override
  void didUpdateWidget(SubtitleOverlay old) {
    super.didUpdateWidget(old);
    // Wenn sich der entries-Stream oder positionStream ändert
    // (z.B. Track-Wechsel, neue Episode), neu subscriben.
    if (old.positionStream != widget.positionStream) {
      _sub?.cancel();
      _sub = widget.positionStream.listen((pos) {
        if (!mounted) return;
        _position = pos;
        _updateText();
      });
    }
    if (old.entries != widget.entries) {
      _updateText();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _updateText() {
    final newText = SrtParser.findActiveText(widget.entries, _position);
    if (newText != _currentText) {
      setState(() => _currentText = newText);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _currentText;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      // Etwas Abstand vom unteren Rand — nicht direkt am Bildrand
      // anliegen damit's auf iPhones mit Home-Indicator nicht
      // unterm Indicator klebt.
      bottom: 48,
      child: IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w500,
                height: 1.2,
                shadows: [
                  Shadow(
                    color: Colors.black,
                    offset: Offset(1, 1),
                    blurRadius: 3,
                  ),
                  Shadow(
                    color: Colors.black,
                    offset: Offset(-1, -1),
                    blurRadius: 3,
                  ),
                  Shadow(
                    color: Colors.black,
                    offset: Offset(1, -1),
                    blurRadius: 3,
                  ),
                  Shadow(
                    color: Colors.black,
                    offset: Offset(-1, 1),
                    blurRadius: 3,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
