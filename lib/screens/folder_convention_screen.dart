import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// User-facing guide to the media folder structure & naming conventions.
class FolderConventionScreen extends StatelessWidget {
  const FolderConventionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ordner-Konvention'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          _intro(context),
          const SizedBox(height: 24),

          _sectionTitle(context, 'So sieht der Medien-Ordner aus'),
          const SizedBox(height: 12),
          _folderTreeCard(),
          const SizedBox(height: 28),

          _sectionTitle(context, 'Grundregeln'),
          const SizedBox(height: 12),
          _ruleCard(
            icon: Icons.tv_rounded,
            title: 'Serien',
            description:
                'Ordner auf oberster Ebene mit „Season"-Unterordnern werden als Serie erkannt. '
                'Jeder Staffel-Ordner enthält die Episoden-Dateien.',
            highlights: const [
              'Serien-Ordner: z. B. „Breaking Bad"',
              'Staffel-Ordner: „Season 1", „Season 2", …',
              'Staffel-Namen können auch „Staffel 1" oder „S01" sein',
            ],
          ),
          const SizedBox(height: 12),
          _ruleCard(
            icon: Icons.movie_rounded,
            title: 'Filme',
            description:
                'Eine einzelne Videodatei auf oberster Ebene oder in einem Ordner ohne '
                'Staffel-Unterordner wird als Film behandelt.',
            highlights: const [
              'Film als eigener Ordner (mit Cover)',
              'Oder einzelne Videodatei direkt im Medien-Ordner',
            ],
          ),
          const SizedBox(height: 12),
          _ruleCard(
            icon: Icons.label_rounded,
            title: 'Episoden-Benennung',
            description:
                'Episoden-Nummer irgendwo im Dateinamen, damit die Reihenfolge stimmt. '
                'Das S##E##-Format funktioniert am zuverlässigsten.',
            highlights: const [
              'Empfohlen: „S01E03 - Titel.mp4"',
              'Alternativen: „1x03 - Titel.mp4"',
              'Alles außer der Episoden-Nummer ist optional',
            ],
          ),
          const SizedBox(height: 12),
          _ruleCard(
            icon: Icons.image_rounded,
            title: 'Drei Bilder pro Medium: Cover · Banner · Thumbnail',
            description:
                'Jedes Bild hat einen anderen Zweck in der App. Alle drei '
                'sind optional — fehlt eines, greift eine Fallback-Kaskade. '
                'Fehlt alles, erzeugt die App ein Standbild aus dem Video.',
            highlights: const [
              'cover.jpg — Hauptkachel auf der Startseite (Hochformat, ~300×450)',
              'banner.jpg — großes Kopfbild in der Detail-Ansicht (~1280×400)',
              'thumbnail.jpg — Karte in der „Weiterschauen"-Leiste (16:9)',
              'Alle Dateien im Wurzel-Ordner des Films / der Serie',
              '.jpg und .png werden akzeptiert',
              'Alternativ-Namen fürs Cover: poster.jpg · folder.jpg',
              'Fallback Startseite:     cover → thumbnail → banner → Auto',
              'Fallback Detail-Banner:  banner → cover → thumbnail',
              'Fallback Weiterschauen:  thumbnail → banner → cover → Auto',
              'Pro-Tipp: „folder.jpg" wird zusätzlich vom Windows-Explorer als '
                  'Ordner-Thumbnail angezeigt',
            ],
          ),
          const SizedBox(height: 12),
          _ruleCard(
            icon: Icons.subtitles_rounded,
            title: 'Untertitel',
            description:
                'Untertitel werden auf zwei Arten unterstützt: extern als eigene '
                'Datei neben dem Video, oder eingebettet (bei .mkv meistens '
                'automatisch dabei). Für externe Dateien zählt vor allem eins: '
                'der Dateiname muss exakt gleich lauten wie der Video-Dateiname, '
                'nur mit einer Untertitel-Endung.',
            highlights: const [
              'Regel: gleicher Name wie das Video — nur andere Endung',
              'Beispiel: „S01E01 - Pilot.mp4" → „S01E01 - Pilot.srt"',
              'Datei liegt im selben Ordner wie das Video',
              'Erlaubte Endungen: .srt · .sub · .ass · .ssa · .vtt',
              'Eingebettete Untertitel in .mkv werden automatisch erkannt',
              'Ein/Aus-Schalter im Player oben rechts, auch während der Wiedergabe',
            ],
          ),
          const SizedBox(height: 12),
          _ruleCard(
            icon: Icons.play_circle_outline_rounded,
            title: 'Unterstützte Video-Formate',
            description:
                'Das sind die Dateitypen, die beim Scan erkannt und abgespielt werden.',
            highlights: const [
              '.mp4 — Standard-Container, kleinste Dateien',
              '.mkv — empfohlen (unterstützt eingebettete Untertitel + mehrere Tonspuren)',
              '.avi — älterer Container, funktioniert',
              '.iso — DVD-/Blu-ray-Image-Dateien',
            ],
          ),

          const SizedBox(height: 28),
          _sectionTitle(context, 'Tipps'),
          const SizedBox(height: 12),
          _tipCard(
            icon: Icons.refresh_rounded,
            text:
                'Neue Dateien oder Ordner hinzugefügt? Über „Bibliothek aktualisieren" '
                'in den Einstellungen oder das Aktualisieren-Symbol oben rechts scannen.',
          ),
          const SizedBox(height: 10),
          _tipCard(
            icon: Icons.auto_awesome_rounded,
            text:
                'Beim ersten Scan werden Vorschaubilder für die Seekleiste im Hintergrund '
                'erzeugt — die Fortschrittsanzeige oben verschwindet wenn fertig.',
          ),
          const SizedBox(height: 10),
          _tipCard(
            icon: Icons.cleaning_services_rounded,
            text:
                'Videos aus dem Medien-Ordner gelöscht? Bei der nächsten Aktualisierung '
                'werden die zugehörigen Vorschaubilder automatisch aufgeräumt.',
          ),
        ],
      ),
    );
  }

  Widget _intro(BuildContext context) {
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
              'BeefburgerStreaming scannt deinen Medien-Ordner automatisch. '
              'Wenn du die folgenden Konventionen einhältst, werden Serien, Filme, '
              'Cover und Untertitel korrekt erkannt.',
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

  Widget _folderTreeCard() {
    const tree = '''Medien-Ordner/
├── Breaking Bad/              ← Serie
│   ├── Season 1/
│   │   ├── S01E01 - Pilot.mp4
│   │   ├── S01E01 - Pilot.srt   ← Untertitel (gleicher Name)
│   │   └── S01E02 - Cat's in the Bag.mkv
│   ├── Season 2/
│   │   └── S02E01 - Seven Thirty-Seven.mkv
│   └── cover.jpg
│
├── Inception/                 ← Film (eigener Ordner)
│   ├── Inception.mp4
│   ├── Inception.srt          ← Untertitel
│   └── cover.jpg
│
└── Pulp Fiction.mp4           ← Film (einzelne Datei)''';

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
            fontFamily: 'Consolas, Courier New, monospace',
            fontFamilyFallback: ['Consolas', 'Courier New', 'monospace'],
            color: AppTheme.textPrimary,
            fontSize: 13,
            height: 1.55,
          ),
        ),
      ),
    );
  }

  Widget _ruleCard({
    required IconData icon,
    required String title,
    required String description,
    required List<String> highlights,
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
          Text(
            description,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          ...highlights.map((h) => Padding(
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
                        h,
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
