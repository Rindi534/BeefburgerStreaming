import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Ordner-Konvention — platform-conditional. Auf Windows zeigt sie
/// die Pfad-Logik des frei waehlbaren Medien-Ordners, auf iOS die
/// Logik des "Auf meinem iPhone"-Ordners. Beide in derselben Datei,
/// um Branch-Merge-Konflikte zu vermeiden.
class FolderConventionScreen extends StatelessWidget {
  const FolderConventionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isWindows = Platform.isWindows;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ordner-Konvention'),
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
        'BeefburgerStreaming scannt einen frei waehlbaren Ordner auf '
        'deinem PC. Diese Anleitung zeigt, wie der Ordner aufgebaut '
        'sein muss, damit Serien, Filme, Cover und Untertitel beim '
        'Scan korrekt erkannt werden.',
      ),
      const SizedBox(height: 24),

      _sectionTitle(context, '1. Medien-Ordner waehlen'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.folder_open_rounded,
        title: 'Wo darf der Ordner liegen?',
        bullets: const [
          'Lokale Festplatte (C:\\, D:\\, …) — schnellster Zugriff',
          'Externe HDD oder SSD — funktioniert genauso',
          'NAS oder Netzlaufwerk — funktioniert, Performance je nach Verbindung',
          'Der Ordner darf frei benannt sein',
          'Wechseln jederzeit unter Einstellungen → Medien-Ordner',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '2. So sieht der Ordner aus'),
      const SizedBox(height: 12),
      _treeCard(_windowsTree),

      const SizedBox(height: 28),
      _sectionTitle(context, '3. Grundregeln'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.tv_rounded,
        title: 'Serien',
        bullets: const [
          'Ordner auf oberster Ebene mit Season-Unterordnern wird als Serie erkannt',
          'Serien-Ordner: z.B. "Breaking Bad"',
          'Staffel-Ordner: "Season 1", "Staffel 1" oder "S01"',
          'In jedem Staffel-Ordner liegen die Episoden-Dateien',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.movie_rounded,
        title: 'Filme',
        bullets: const [
          'Eine einzelne Videodatei direkt im Medien-Ordner — fertig',
          'Oder ein eigener Film-Ordner mit Video + Cover drin',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.label_rounded,
        title: 'Episoden-Benennung',
        bullets: const [
          'Episoden-Nummer im Dateinamen, damit die Reihenfolge stimmt',
          'Empfohlen: "S01E03 - Titel.mkv"',
          'Alternativ: "1x03 - Titel.mkv"',
          'Alles ausser der Episoden-Nummer ist optional',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '4. Bilder'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.image_rounded,
        title: 'Cover, Banner, Thumbnail',
        bullets: const [
          'cover.jpg — Hauptkachel auf der Startseite (~300x450, Hochformat)',
          'banner.jpg — grosses Kopfbild in der Detail-Ansicht (~1280x400)',
          'thumbnail.jpg — Karte in der Weiterschauen-Leiste (16:9)',
          'Alle drei optional — fehlt eines, greift eine Fallback-Kaskade',
          'Fehlt alles, erzeugt die App ein Standbild aus dem Video',
          'Alternativ-Namen fuers Cover: poster.jpg, folder.jpg',
          'PNG oder JPG, im Wurzel-Ordner des Films / der Serie',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '5. Untertitel'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.subtitles_rounded,
        title: 'Extern oder eingebettet',
        bullets: const [
          'Eingebettete Untertitel in .mkv werden automatisch erkannt',
          'Externe Datei: gleicher Name wie das Video, nur andere Endung',
          'Beispiel: "S01E01 - Pilot.mkv" + "S01E01 - Pilot.srt"',
          'Datei liegt im selben Ordner wie das Video',
          'Erlaubte Endungen: .srt, .sub, .ass, .ssa, .vtt',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '6. Unterstuetzte Formate'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.play_circle_outline_rounded,
        title: 'Welche Video-Formate?',
        bullets: const [
          '.mkv — empfohlen (eingebettete Untertitel + mehrere Tonspuren)',
          '.mp4, .mov, .m4v — Standard-Container',
          '.avi, .wmv, .flv — aeltere Container, werden auch gelesen',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '7. Tipps'),
      const SizedBox(height: 12),
      _tipCard(
        icon: Icons.refresh_rounded,
        text:
            'Neue Dateien oder Ordner hinzugefuegt? F5 oder das Aktualisieren-'
            'Symbol oben rechts auf der Startseite.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.auto_awesome_rounded,
        text:
            'Beim ersten Scan werden Vorschaubilder im Hintergrund erzeugt — '
            'du kannst waehrenddessen schon ganz normal schauen.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.cleaning_services_rounded,
        text:
            'Datei spaeter aus dem Ordner geloescht? Bei der naechsten '
            'Aktualisierung werden die zugehoerigen Vorschaubilder automatisch '
            'aufgeraeumt — es sei denn, du hast das Medium in der Cache-'
            'Verwaltung gemerkt.',
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
        'BeefburgerStreaming nutzt einen eigenen Ordner in der iOS-'
        'Dateien-App. Diese Anleitung zeigt, wie du Videos auf das '
        'Geraet bekommst und den Ordner so aufbaust, dass Serien, '
        'Filme, Cover und Untertitel beim Scan korrekt erkannt werden.',
      ),
      const SizedBox(height: 24),

      _sectionTitle(context, '1. Videos aufs iPhone/iPad bringen'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.folder_shared_rounded,
        title: 'Ueber die Dateien-App',
        bullets: const [
          'Dateien-App oeffnen',
          'Reiter "Durchsuchen" → "Auf meinem iPhone/iPad"',
          'Ordner "BeefburgerStreaming" auswaehlen',
          'Hier deine Filme- und Serien-Ordner reinkopieren',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.cable_rounded,
        title: 'Vom Computer uebertragen',
        bullets: const [
          'Mac: iPhone per Kabel → Finder → iPhone-Eintrag → "Dateien" → BeefburgerStreaming',
          'Windows: Apple Devices App → Dateifreigabe → BeefburgerStreaming',
          'AirDrop: einzelne Videos vom Mac/iPhone an die App teilen',
          'Cloud (iCloud, Dropbox …): Datei → "In Dateien sichern" → BeefburgerStreaming',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '2. So sieht der Ordner aus'),
      const SizedBox(height: 12),
      _treeCard(_iosTree),

      const SizedBox(height: 28),
      _sectionTitle(context, '3. Grundregeln'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.tv_rounded,
        title: 'Serien',
        bullets: const [
          'Ordner auf oberster Ebene mit Season-Unterordnern wird als Serie erkannt',
          'Serien-Ordner: z.B. "Breaking Bad"',
          'Staffel-Ordner: "Season 1", "Staffel 1" oder "S01"',
          'In jedem Staffel-Ordner liegen die Episoden-Dateien',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.movie_rounded,
        title: 'Filme',
        bullets: const [
          'Eine einzelne Videodatei direkt im Medien-Ordner — fertig',
          'Oder ein eigener Film-Ordner mit Video + Cover drin',
        ],
      ),
      const SizedBox(height: 12),
      _card(
        icon: Icons.label_rounded,
        title: 'Episoden-Benennung',
        bullets: const [
          'Episoden-Nummer im Dateinamen, damit die Reihenfolge stimmt',
          'Empfohlen: "S01E03 - Titel.mkv"',
          'Alternativ: "1x03 - Titel.mkv"',
          'Alles ausser der Episoden-Nummer ist optional',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '4. Bilder'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.image_rounded,
        title: 'Cover, Banner, Thumbnail',
        bullets: const [
          'cover.jpg — Hauptkachel auf der Startseite (~300x450, Hochformat)',
          'banner.jpg — grosses Kopfbild in der Detail-Ansicht (~1280x400)',
          'thumbnail.jpg — Karte in der Weiterschauen-Leiste (16:9)',
          'Alle drei optional — fehlt eines, greift eine Fallback-Kaskade',
          'Fehlt alles, erzeugt die App ein Standbild aus dem Video',
          'Alternativ-Namen fuers Cover: poster.jpg, folder.jpg',
          'PNG oder JPG, im Wurzel-Ordner des Films / der Serie',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '5. Untertitel'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.subtitles_rounded,
        title: 'Extern oder eingebettet',
        bullets: const [
          'Eingebettete Untertitel in .mkv werden automatisch erkannt',
          'Externe Datei: gleicher Name wie das Video, nur andere Endung',
          'Beispiel: "S01E01 - Pilot.mkv" + "S01E01 - Pilot.srt"',
          'Datei liegt im selben Ordner wie das Video',
          'Erlaubte Endungen: .srt, .sub, .ass, .ssa, .vtt',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '6. Unterstuetzte Formate'),
      const SizedBox(height: 12),
      _card(
        icon: Icons.play_circle_outline_rounded,
        title: 'Welche Video-Formate?',
        bullets: const [
          '.mkv — empfohlen (eingebettete Untertitel + mehrere Tonspuren)',
          '.mp4, .mov, .m4v — Standard-Container',
          '.avi — aelterer Container, wird auch gelesen',
        ],
      ),

      const SizedBox(height: 28),
      _sectionTitle(context, '7. Tipps'),
      const SizedBox(height: 12),
      _tipCard(
        icon: Icons.refresh_rounded,
        text:
            'Neue Dateien oder Ordner hinzugefuegt? Aktualisieren-Symbol oben '
            'rechts auf der Startseite tippen.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.auto_awesome_rounded,
        text:
            'Beim ersten Scan werden Vorschaubilder im Hintergrund erzeugt — '
            'du kannst waehrenddessen schon ganz normal schauen.',
      ),
      const SizedBox(height: 10),
      _tipCard(
        icon: Icons.cleaning_services_rounded,
        text:
            'Datei spaeter aus dem Ordner geloescht? Bei der naechsten '
            'Aktualisierung werden die zugehoerigen Vorschaubilder automatisch '
            'aufgeraeumt — es sei denn, du hast das Medium gemerkt.',
      ),
    ];
  }

  // ──────────────────────────────────────────────────────────────
  //                       O R D N E R - B Ä U M E
  // ──────────────────────────────────────────────────────────────

  static const String _windowsTree = '''D:\\Filme\\                    ← dein gewaehlter Medien-Ordner
├── Breaking Bad\\              ← Serie
│   ├── Season 1\\
│   │   ├── S01E01 - Pilot.mkv
│   │   ├── S01E01 - Pilot.srt   ← externe Untertitel
│   │   └── S01E02 - Cat's in the Bag.mkv
│   ├── Season 2\\
│   │   └── S02E01 - Seven Thirty-Seven.mkv
│   └── cover.jpg
│
├── Inception\\                 ← Film (eigener Ordner)
│   ├── Inception.mkv
│   ├── Inception.srt
│   └── cover.jpg
│
└── Pulp Fiction.mp4           ← Film (einzelne Datei)''';

  static const String _iosTree = '''BeefburgerStreaming/         ← in der Dateien-App
├── Breaking Bad/              ← Serie
│   ├── Season 1/
│   │   ├── S01E01 - Pilot.mkv
│   │   ├── S01E01 - Pilot.srt   ← externe Untertitel
│   │   └── S01E02 - Cat's in the Bag.mkv
│   ├── Season 2/
│   │   └── S02E01 - Seven Thirty-Seven.mkv
│   └── cover.jpg
│
├── Inception/                 ← Film (eigener Ordner)
│   ├── Inception.mkv
│   ├── Inception.srt
│   └── cover.jpg
│
└── Pulp Fiction.mp4           ← Film (einzelne Datei)''';

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
          const Icon(Icons.info_outline_rounded,
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

  Widget _treeCard(String tree) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          tree,
          style: const TextStyle(
            fontFamily: 'Courier',
            fontFamilyFallback: ['Menlo', 'Courier New', 'monospace'],
            color: AppTheme.textPrimary,
            fontSize: 13,
            height: 1.55,
          ),
        ),
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
