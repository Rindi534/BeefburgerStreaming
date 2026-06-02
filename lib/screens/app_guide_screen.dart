import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// In-App-Anleitung — komplett platform-conditional. Auf Windows
/// laeuft [_windowsChildren], auf iOS/iPad [_iosChildren]. Beide
/// Bodies leben in dieser einen Datei, damit kein Branch-Merge
/// sie mehr gegenseitig ueberschreiben kann.
class AppGuideScreen extends StatelessWidget {
  const AppGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isWindows = Platform.isWindows;
    return Scaffold(
      appBar: AppBar(
        title: const Text('App-Anleitung'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: isWindows
            ? _windowsChildren(context)
            : _iosChildren(context),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  //                          W I N D O W S
  // ──────────────────────────────────────────────────────────────

  List<Widget> _windowsChildren(BuildContext context) {
    return [
      _intro(
        context,
        'Komplette Anleitung fuer BeefburgerStreaming auf Windows. '
        'Wie du den Medien-Ordner aufbaust, steht eine Ebene hoeher in '
        'den Einstellungen unter "Ordner-Konvention".',
      ),
      const SizedBox(height: 24),

      _sectionTitle(context, '1. Erster Start'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.rocket_launch_rounded,
        title: 'In drei Schritten startklar',
        bullets: const [
          'Medien-Ordner anlegen — siehe "Ordner-Konvention"',
          'App starten, oben rechts aufs Zahnrad',
          '"Medien-Ordner waehlen" → den Ordner aussuchen',
          'Der Scan laeuft automatisch los — fertig',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '2. Startseite'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.home_rounded,
        title: 'Was du hier siehst',
        bullets: const [
          'Logo + Suchleiste oben',
          'Aktualisieren-Knopf (oder F5) und Zahnrad rechts oben',
          'Weiterschauen-Leiste sobald etwas angefangen wurde',
          'Darunter das Raster aller Filme und Serien',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.search_rounded,
        title: 'Suche',
        bullets: const [
          'Live-Filter — tippst du etwas, kommen Treffer sofort',
          'Treffer gruppiert nach Filmen, Serien und Folgen',
          'Klick auf einen Treffer startet ihn direkt',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.history_rounded,
        title: 'Weiterschauen-Leiste',
        bullets: const [
          'Mausrad scrollt durch die Karten',
          'Maus-Drag zum schnelleren Durchblaettern',
          'Fortschrittsbalken unter jeder Karte',
          'Klick spielt direkt an der letzten Position weiter',
          'Ab 90 % gilt etwas als gesehen und faellt heraus',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '3. Detail-Ansicht'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.view_list_rounded,
        title: 'Film oder Serie',
        bullets: const [
          'Filme: Abspielen-Knopf, bei Fortschritt zusaetzlich Weiterschauen + Neu starten',
          'Serien: Staffel-Auswahl + Episoden-Liste',
          'Zuletzt gesehene Folge ist markiert',
          'Pfeil oben links zurueck',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '4. Player'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.play_circle_filled_rounded,
        title: 'Grundbedienung',
        bullets: const [
          'Klick aufs Video pausiert/spielt',
          'Steuerleiste blendet nach 3 Sek aus, kommt bei Mausbewegung zurueck',
          'Position wird automatisch gespeichert',
          'Esc oder Pfeil zurueck schliesst den Player',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.fullscreen_rounded,
        title: 'Vollbild (F oder F11)',
        bullets: const [
          'Borderless — kein Fensterrahmen, fuellt den ganzen Monitor',
          'Bei Multi-Monitor: nutzt den Bildschirm, auf dem das Fenster liegt',
          'Neue Programme poppen oberhalb, ohne dass die Taskleiste auftaucht',
          'Klick auf einen anderen Monitor laesst den Vollbild-Modus in Ruhe',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.subtitles_rounded,
        title: 'Untertitel',
        bullets: const [
          'Eingebettet in MKV oder externe ".srt" werden automatisch erkannt',
          'Sprechblasen-Symbol oeffnet die Spur-Auswahl',
          'Taste C oder S togglet zwischen Aus und der zuletzt gewaehlten Spur',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.music_note_rounded,
        title: 'Audio-Spuren',
        bullets: const [
          'Note-Icon oeffnet die Spur-Auswahl',
          'Aus oder eine bestimmte Sprache (DE, EN, …)',
          'Taste A togglet zwischen Aus und der ersten Spur',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.skip_next_rounded,
        title: 'Naechste Folge',
        bullets: const [
          'Am Folgenende erscheint ein Countdown-Knopf',
          'Klick oder Enter startet sofort',
          'Backspace oder Klick danebem: Abspann ansehen, kein Auto-Play',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.lock_rounded,
        title: 'Lock-Modus',
        bullets: const [
          'Taste L oder Klick aufs Schloss-Icon oben rechts',
          'Alle Klicks und Tasten gesperrt, nur Anzeige bleibt',
          'Sichtbar: Serientitel, Folge, Zeit, Progressbar, Schloss',
          'Auch das blendet nach 3 Sek aus',
          'Aufschliessen: das Schloss 5 Sekunden gedrueckt halten — roter Ring fuellt sich',
          'Naechste-Folge-Knopf bleibt im Lock klickbar',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.photo_camera_rounded,
        title: 'Screenshot + Clip (optional)',
        bullets: const [
          'In den Einstellungen "Erweiterte Werkzeuge" aktivieren',
          'Kamera-Icon: PNG-Foto der aktuellen Szene',
          'Video-Icon: 1. Klick = Anfang, 2. Klick = Ende + Dateiname',
          'Clip wird ohne Re-Encoding gespeichert (schnell + verlustfrei)',
          'Zielordner in den Einstellungen unter "Export-Ordner"',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '5. Cache-Verwaltung'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.refresh_rounded,
        title: 'Bibliothek aktualisieren',
        bullets: const [
          'F5 oder Aktualisieren-Symbol rechts oben',
          'Dialog zeigt was neu / geaendert / verschwunden ist',
          'Haken setzen = Vorschaubild erzeugen, aktualisieren oder loeschen',
          'Ohne Haken bleibt alles wie gehabt',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.shield_rounded,
        title: 'Wichtige Medien merken',
        bullets: const [
          'Jedes Medium hat ein Schild-Symbol',
          'Klick darauf merkt das Medium dauerhaft',
          'Geloeschte Datei + gemerkt = Cover bleibt, Eintrag landet im Archiv',
          'Sinnvoll fuer Lieblings-Inhalte die du temporaer entfernst',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.delete_sweep_rounded,
        title: 'Cache aufraeumen',
        bullets: const [
          'Pro Medium einzeln zuruecksetzen',
          'Bulk-Aktionen: "Alle merken" oder "Komplett zuruecksetzen"',
          'Originaldateien werden NIE angefasst',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '6. Tastenkuerzel'),
      const SizedBox(height: 12),
      _tipCard(
        icon: Icons.keyboard_rounded,
        text:
            'Space / Klick aufs Video → Play/Pause   ·   ← / → → ±10 Sek   ·   '
            '↑ / ↓ → Lautstaerke ±5 %   ·   M → Stumm   ·   '
            'C oder S → Untertitel   ·   A → Audio   ·   '
            'F / F11 → Vollbild   ·   L → Lock-Modus   ·   '
            'Enter → Sofort naechste Folge   ·   Esc → Player zu',
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '7. Gut zu wissen'),
      const SizedBox(height: 12),
      _tipCard(
        icon: Icons.lock_outline_rounded,
        text:
            'Alles bleibt lokal auf deinem PC. Keine Uploads, kein Account, '
            'kein Internet noetig.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.folder_outlined,
        text:
            'Die App veraendert deine Original-Videos NIE. Nur die Cache-'
            'Datenbank und Vorschaubilder werden in den App-Daten gespeichert.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.bedtime_outlined,
        text:
            'Sleep-Modus (Einstellungen): wenn an, wird der Player-Fortschritt '
            'NICHT gespeichert. Sichtbar im Player am Mond-Icon. Praktisch '
            'zum Probe-Schauen.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.image_outlined,
        text:
            'Vorschaubild der Progressbar: Maus ueber die Leiste fahren zeigt '
            'die Szene an der Stelle. Deaktivierbar in den Einstellungen.',
      ),
    ];
  }

  // ──────────────────────────────────────────────────────────────
  //                          i O S  /  iPad
  // ──────────────────────────────────────────────────────────────

  List<Widget> _iosChildren(BuildContext context) {
    return [
      _intro(
        context,
        'Komplette Anleitung fuer BeefburgerStreaming auf iPhone und iPad. '
        'Wie du Videos auf das Geraet bekommst und den Ordner aufbaust, '
        'steht eine Ebene hoeher in den Einstellungen unter "Ordner-Konvention".',
      ),
      const SizedBox(height: 24),

      _sectionTitle(context, '1. Erster Start'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.rocket_launch_rounded,
        title: 'In drei Schritten startklar',
        bullets: const [
          'Videos in den BeefburgerStreaming-Ordner der iOS-Dateien-App legen',
          'App starten, oben rechts aufs Zahnrad tippen',
          '"Medien-Ordner waehlen" → den Ordner aussuchen',
          'Der Scan laeuft automatisch los — fertig',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '2. Startseite'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.home_rounded,
        title: 'Was du hier siehst',
        bullets: const [
          'Logo + Suchleiste oben',
          'Aktualisieren-Knopf und Zahnrad rechts oben',
          'Weiterschauen-Leiste sobald etwas angefangen wurde',
          'Darunter das Raster aller Filme und Serien',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.search_rounded,
        title: 'Suche',
        bullets: const [
          'Live-Filter — tippen, Treffer kommen sofort',
          'Treffer gruppiert nach Filmen, Serien und Folgen',
          'Tap auf einen Treffer startet ihn direkt',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.history_rounded,
        title: 'Weiterschauen-Leiste',
        bullets: const [
          'Horizontal wischen zum Durchblaettern',
          'Fortschrittsbalken unter jeder Karte',
          'Tap spielt direkt an der letzten Position weiter',
          'Ab 90 % gilt etwas als gesehen und faellt heraus',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '3. Detail-Ansicht'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.view_list_rounded,
        title: 'Film oder Serie',
        bullets: const [
          'Filme: Abspielen-Knopf, bei Fortschritt zusaetzlich Weiterschauen + Neu starten',
          'Serien: Staffel-Chips + Episoden-Liste',
          'Zuletzt gesehene Folge ist markiert',
          'Pfeil oben links zurueck',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '4. Player'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.play_circle_filled_rounded,
        title: 'Grundbedienung',
        bullets: const [
          'Player startet automatisch im Querformat',
          'Tap aufs Video pausiert/spielt',
          'Steuerleiste blendet nach 3 Sek aus, kommt mit dem naechsten Tap zurueck',
          'X oben links schliesst den Player, Position wird gemerkt',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.subtitles_rounded,
        title: 'Untertitel',
        bullets: const [
          'Eingebettet in MKV oder externe ".srt" werden automatisch erkannt',
          'Untertitel-Icon oben rechts oeffnet die Spur-Auswahl',
          'Aus oder eine bestimmte Spur tappen',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.music_note_rounded,
        title: 'Audio-Spuren',
        bullets: const [
          'Note-Icon oben rechts oeffnet die Spur-Auswahl',
          'Aus oder eine bestimmte Sprache (DE, EN, …)',
          'Bei Pause + Play kann der Ton 1-2 Sek brauchen bis er wieder einsetzt '
              '(MobileVLCKit-Eigenheit, bei MP4-Dateien tritts nicht auf)',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.picture_in_picture_alt_rounded,
        title: 'Picture-in-Picture (PiP)',
        bullets: const [
          'PiP-Icon oben rechts oeffnet das Mini-Fenster',
          'Du kannst die App verlassen, das Video laeuft im Bild-im-Bild weiter',
          'Beim Folgenende startet die naechste Folge automatisch in PiP',
          'Beenden: PiP-Fenster antippen + Vollbild-Symbol',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.skip_next_rounded,
        title: 'Naechste Folge',
        bullets: const [
          'Am Folgenende erscheint ein Countdown-Knopf',
          'Tap startet sofort',
          'Tap ausserhalb des Knopfes: Abspann ansehen, kein Auto-Play',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.lock_rounded,
        title: 'Lock-Modus',
        bullets: const [
          'Tap aufs Schloss-Icon oben rechts (offenes Schloss)',
          'Alle Touches und Tasten gesperrt, nur Anzeige bleibt',
          'Sichtbar: Titel, Folge, Zeit, Progressbar, grosses Schloss',
          'Auch das blendet nach 3 Sek aus, kommt mit dem naechsten Tap zurueck',
          'Aufschliessen: das grosse Schloss 5 Sekunden gedrueckt halten — roter Ring fuellt sich',
          'Naechste-Folge-Knopf bleibt im Lock tappbar',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '5. Sperrbildschirm & AirPlay'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.lock_clock_rounded,
        title: 'Now-Playing-Karte',
        bullets: const [
          'Auf dem Sperrbildschirm + im Kontrollzentrum',
          'Titel, Folge und Cover werden angezeigt',
          'Play/Pause und Skip-Buttons direkt nutzbar',
          'Hardware-Lautstaerketasten regeln den Player-Ton',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.airplay_rounded,
        title: 'AirPlay',
        bullets: const [
          'Audio + Video an Apple TV, HomePod oder andere AirPlay-Geraete senden',
          'Auswahl ueber das iOS-Kontrollzentrum (rechts oben wischen → AirPlay-Icon)',
          'Wiedergabe-Steuerung bleibt am iPhone/iPad',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '6. iPad-Tastatur (optional)'),
      const SizedBox(height: 12),
      _tipCard(
        icon: Icons.keyboard_rounded,
        text:
            'Space → Play/Pause   ·   ← / → → ±10 Sek   ·   '
            'C oder S → Untertitel   ·   A → Audio   ·   '
            'P → Picture-in-Picture   ·   L → Lock-Modus   ·   '
            'Backspace → Player schliessen',
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '7. Gut zu wissen'),
      const SizedBox(height: 12),
      _tipCard(
        icon: Icons.lock_outline_rounded,
        text:
            'Alles bleibt lokal auf deinem Geraet. Keine Uploads, kein Account, '
            'kein Internet noetig.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.folder_outlined,
        text:
            'Die App veraendert deine Original-Videos NIE. Nur die Cache-'
            'Datenbank und Vorschaubilder werden in den App-Daten gespeichert.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.bedtime_outlined,
        text:
            'Sleep-Modus (Einstellungen): wenn an, wird der Player-Fortschritt '
            'NICHT gespeichert. Sichtbar im Player am Mond-Icon. Praktisch '
            'zum Probe-Schauen.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.headphones_outlined,
        text:
            'Bluetooth-Kopfhoerer und AirPods funktionieren wie gewohnt. '
            'Bei Bluetooth gibt es im Stream eine kleine technische Latenz, '
            'das ist normal.',
      ),
    ];
  }

  // ──────────────────────────────────────────────────────────────
  //                       S H A R E D   W I D G E T S
  // ──────────────────────────────────────────────────────────────

  Widget _intro(BuildContext context, String text) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.menu_book_rounded,
              color: AppTheme.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppTheme.textPrimary.withValues(alpha: 0.9),
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: AppTheme.accent,
            fontWeight: FontWeight.w700,
          ),
    );
  }

  Widget _card({
    required IconData icon,
    required String title,
    required List<String> bullets,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppTheme.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...bullets.map((b) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 6, right: 10),
                      child: Icon(Icons.circle,
                          size: 5, color: AppTheme.accent),
                    ),
                    Expanded(
                      child: Text(
                        b,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13.5,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _tipCard({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
