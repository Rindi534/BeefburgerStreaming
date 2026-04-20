import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// In-app guide covering every feature of the app. Paired with
/// [FolderConventionScreen] which handles the "how do I prepare the
/// files" side of things. Both are reachable from Settings > Hilfe.
class AppGuideScreen extends StatelessWidget {
  const AppGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App-Anleitung'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          _intro(context),
          const SizedBox(height: 24),

          // ─────────────────────────── Navigation ───────────────────────────
          _sectionTitle(context, 'Navigation'),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.home_rounded,
            title: 'Startseite',
            description:
                'Zentraler Einstieg mit Raster aller Filme und Serien. '
                'Oben: Logo, globale Suchleiste, Aktualisieren- und '
                'Einstellungs-Button. Darunter — sobald du etwas '
                'angefangen hast — die „Weiterschauen"-Leiste, danach '
                'das vollständige Raster.',
            highlights: const [
              'Jede Kachel zeigt das Cover-Bild',
              'Fehlt ein Cover, wird ein Auto-Frame aus dem Video genutzt',
              'Hover-Effekt: sanfter Zoom',
              'Klick auf eine Kachel → Detail-Ansicht',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.search_rounded,
            title: 'Globale Suchleiste',
            description:
                'Im Kopfbereich der Startseite, zwischen Logo und den '
                'rechten Buttons. Tippe los — es wird live gefiltert, '
                'ein Dropdown mit den Treffern erscheint direkt darunter. '
                'Gruppen: Filme, Serien, Folgen.',
            highlights: const [
              'Film anklicken → startet direkt im Player',
              'Serie anklicken → öffnet die Detail-Ansicht',
              'Folge anklicken → spielt die Folge sofort — die '
                  'nächste Folge wird automatisch angehängt und die '
                  'Position wird gemerkt',
              'Filme und Serien erscheinen mit ihrem Hochformat-Cover, '
                  'Folgen mit einem Querformat-Vorschaubild — so '
                  'erkennst du sofort, worauf du klickst',
              'Treffer am Wortanfang werden zuerst gezeigt',
              'Gibst du einen Serientitel ein, stehen die Folgen '
                  'dieser Serie oben (z. B. „Se" → erst Seinfeld-'
                  'Folgen, dann alles andere mit „se")',
              'Escape oder Klick außerhalb schließt das Dropdown',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.history_rounded,
            title: 'Weiterschauen-Leiste',
            description:
                'Horizontale Reihe mit angefangenen Folgen/Filmen. '
                'Ab 90 % Fortschritt gilt etwas als „fertig" und '
                'verschwindet automatisch aus der Leiste.',
            highlights: const [
              'Mausrad-Scrollen über der Leiste',
              'Maus-Drag: reinklicken und ziehen',
              'Pfeil-Buttons links/rechts erscheinen bei Overflow, '
                  'verschwinden wenn alles ins Bild passt',
              'Federt sanft am Anfang/Ende, wenn du übers Rand '
                  'weiterscrollst — rein visuelles Feedback',
              'Fortschrittsbalken unter jeder Karte',
              'Bild: thumbnail.jpg bevorzugt (16:9), sonst banner/cover',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.view_list_rounded,
            title: 'Detail-Ansicht',
            description:
                'Filme zeigen einen „Abspielen"-Button; Serien zeigen '
                'Staffel-Chips + eine scrollbare Episodenliste. Die '
                'zuletzt gesehene Episode ist markiert, ein '
                '„Weiterschauen"-Button springt direkt dorthin zurück.',
            highlights: const [
              'Großes Kopfbild (banner → cover → thumbnail → Auto)',
              'Staffel-Leiste: Mausrad, Maus-Drag oder Pfeil-Buttons',
              'Staffel-Chips federn am Rand — gleiches Verhalten wie '
                  'die Weiterschauen-Leiste',
              'Klick auf Episode öffnet den Player mit letzter Position',
              'Escape oder Pfeil oben links → zurück',
            ],
          ),

          const SizedBox(height: 28),

          // ─────────────────────────── Player ───────────────────────────
          _sectionTitle(context, 'Video-Player'),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.play_circle_filled_rounded,
            title: 'Steuerung',
            description:
                'Die Steuerleiste blendet sich nach ~3 Sek. ohne '
                'Maus-Bewegung aus. Bei Maus-Bewegung ist sie sofort '
                'wieder da. Position wird automatisch gespeichert.',
            highlights: const [
              'Leertaste oder Doppelklick: Pause/Play',
              'Pfeil links/rechts: 10 Sek zurück/vor',
              'Pfeil hoch/runter: Lautstärke ±5 %',
              'M: stumm · F: Vollbild',
              'Escape: zurück (Position wird gemerkt)',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.subtitles_rounded,
            title: 'Untertitel',
            description:
                'Externe .srt-Dateien (gleicher Name wie das Video) und '
                'eingebettete Untertitel in .mkv werden automatisch '
                'erkannt. Bei mehreren Spuren öffnet sich ein Auswahl-'
                'Menü.',
            highlights: const [
              'Button im Player oder Taste C/S',
              'Standard-Verhalten konfigurierbar in den Einstellungen',
              'Unterstützt: .srt · .sub · .ass · .ssa · .vtt',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.audiotrack_rounded,
            title: 'Audio-Spuren',
            description:
                'Bei Videos mit mehreren Tonspuren (z. B. Deutsch + '
                'Englisch) erscheint automatisch das Musiknoten-Symbol '
                'unten rechts im Player.',
            highlights: const [
              'Taste A: durch alle Spuren schalten',
              'Aktive Spur ist farbig markiert',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.skip_next_rounded,
            title: 'Auto-Play nächste Episode',
            description:
                'Am Ende einer Folge erscheint ein 10-Sekunden-Countdown '
                'mit Vorschau der nächsten Episode aus dem gleichen '
                'Staffel-Ordner.',
            highlights: const [
              '„Jetzt starten": überspringt Countdown',
              '„Abbrechen": Countdown stoppen',
              'Nächste Folge = nächstgrößere Episoden-Nummer im Ordner',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.photo_camera_rounded,
            title: 'Erweiterte Werkzeuge (Screenshot + Clip)',
            description:
                'Opt-in. Aktivieren unter Einstellungen > Wiedergabe > '
                '„Erweiterte Werkzeuge". Dann erscheinen zusätzliche '
                'Buttons + Tastenkürzel im Player.',
            highlights: const [
              'P: Screenshot des aktuellen Frames als PNG',
              '1: Clip-Anfang markieren',
              '2: Clip-Ende markieren + als MP4 speichern',
              'Mindestens 0,5 Sek zwischen Anfang und Ende',
              'Ziel: Export-Ordner in den Einstellungen (sonst Dokumente)',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.preview_rounded,
            title: 'Vorschaubilder in der Seekleiste',
            description:
                'Optional. Beim Hovern über der Seekbar zeigt die App '
                'einen kleinen Frame der Zielposition. Muss erst '
                'aktiviert werden.',
            highlights: const [
              'Einstellungen > Wiedergabe > „Vorschaubilder"',
              'Erstellung läuft im Hintergrund (Balken auf der Startseite)',
              '„Stopp"-Button bricht sauber ab, Fortschritt bleibt erhalten',
              'Absturz-sicher: unfertige Ordner werden neu erkannt',
            ],
          ),

          const SizedBox(height: 28),

          // ───────────────────── Bibliothek & Cache ─────────────────────
          _sectionTitle(context, 'Bibliothek & Cache'),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.refresh_rounded,
            title: 'Bibliothek aktualisieren',
            description:
                'Nach jeder Änderung in deinem Medien-Ordner (neuer '
                'Film, neue Folge, umbenannte Datei, gelöschte Datei) '
                'drückst du oben rechts auf das Aktualisieren-Symbol. '
                'Die App vergleicht den Ordner mit ihrem letzten Stand '
                'und zeigt dir in einem Dialog, was sich geändert hat. '
                'Du bestätigst mit Haken, was davon übernommen werden '
                'soll.',
            highlights: const [
              '🟢 Neue Dateien: Haken setzen, damit direkt ein '
                  'Vorschaubild erzeugt wird',
              '🟠 Geänderte Dateien (gleicher Name, andere Größe): '
                  'Haken setzen, um das Vorschaubild zu erneuern',
              '🔴 Verschwundene Dateien: Haken setzen, wenn auch das '
                  'gespeicherte Vorschaubild mit weg soll',
              'Haken weg lassen = unverändert stehen lassen',
              'Bei vielen Änderungen auf einmal: oben alle an/abwählen',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.shield_rounded,
            title: 'Wichtige Medien „merken"',
            description:
                'Für jeden Film und jede Serie gibt es ein kleines '
                'Schild-Symbol. Wenn du darauf klickst, merkt sich die '
                'App diesen Eintrag. Das heißt: Selbst wenn du die '
                'Datei irgendwann vom Laufwerk entfernst, bleibt das '
                'Vorschaubild in der App erhalten und der Eintrag '
                'rutscht ins Archiv statt einfach zu verschwinden.',
            highlights: const [
              'Sinnvoll für Lieblingsfilme oder -serien, die du ab '
                  'und zu auf eine externe Platte auslagerst',
              'Schild aus + Datei weg → Eintrag wird ganz entfernt',
              'Schild an + Datei weg → Eintrag landet im Archiv',
              'Nichts an der Datei ändert sich — nur die App merkt '
                  'sich, dass sie dir wichtig ist',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.archive_rounded,
            title: 'Archiv',
            description:
                'Hier sammelt die App alle gemerkten Medien, deren '
                'Datei gerade nicht erreichbar ist (z. B. weil die '
                'externe Platte abgesteckt ist). Solange ein Eintrag '
                'im Archiv liegt, bleibt sein Cover/Vorschaubild '
                'erhalten. Steckst du die Platte wieder an und '
                'aktualisierst die Bibliothek, taucht der Eintrag '
                'automatisch wieder normal auf.',
            highlights: const [
              'Mülleimer-Symbol: endgültig aus der App entfernen '
                  '(Originaldatei ist ohnehin schon weg)',
              'Eintrag bleibt, bis du ihn selbst löschst oder die '
                  'Datei wieder auftaucht',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.account_tree_rounded,
            title: 'Vorschaubilder einzeln neu erzeugen',
            description:
                'Wenn ein Cover mal schlecht gewählt ist oder du '
                'einfach ein neues Standbild haben willst: In den '
                'Einstellungen gibt es eine Baum-Ansicht aller Medien. '
                'Klick auf einen Eintrag markiert ihn zum Neu-Erzeugen. '
                'Beim nächsten „Bibliothek aktualisieren" fragt dich '
                'die App dann, ob das neue Bild wirklich erstellt '
                'werden soll.',
            highlights: const [
              'Funktioniert auf jeder Ebene: ganze Serie, eine '
                  'Staffel oder nur eine einzelne Folge',
              'Du entscheidest selbst, wann neu erzeugt wird',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.flash_on_rounded,
            title: 'Alles auf einmal',
            description:
                'Zwei Knöpfe oberhalb der Medien-Liste, falls du mal '
                'aufräumen willst:',
            highlights: const [
              '„Alle merken": setzt das Schild-Symbol bei jedem '
                  'Eintrag auf an',
              '„Merkliste leeren & Archiv löschen": setzt alles '
                  'zurück und räumt das Archiv vollständig aus',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.delete_sweep_rounded,
            title: 'Gesamten Vorschaubild-Cache leeren',
            description:
                'Einstellungen > Daten > „Vorschaubild-Cache leeren". '
                'Löscht wirklich alle generierten Cover und Standbilder '
                '— auch die gemerkten und das Archiv. Deine '
                'Originaldateien (Videos, Untertitel, eigene cover.jpg) '
                'werden NICHT angefasst.',
            highlights: const [
              'Anzeige der aktuellen Cache-Größe vor dem Löschen',
              'Benötigte Bilder werden beim nächsten Aktualisieren '
                  'wieder neu erzeugt',
              'Nützlich z. B. wenn du viel Speicherplatz freimachen '
                  'willst',
            ],
          ),

          const SizedBox(height: 28),

          // ─────────────────────── Tastenkürzel ───────────────────────
          _sectionTitle(context, 'Tastenkürzel (im Player)'),
          const SizedBox(height: 12),
          _shortcutsCard(),

          const SizedBox(height: 28),
          _sectionTitle(context, 'Gut zu wissen'),
          const SizedBox(height: 12),
          _tipCard(
            icon: Icons.lock_rounded,
            text:
                'Alles bleibt lokal. Keine Uploads, kein Account, '
                'kein Internet nötig.',
          ),
          const SizedBox(height: 10),
          _tipCard(
            icon: Icons.folder_rounded,
            text:
                'Die App verändert deine Originaldateien NIE — sie '
                'liest sie nur. Auch „Cache leeren" betrifft nur '
                'generierte Vorschaubilder.',
          ),
          const SizedBox(height: 10),
          _tipCard(
            icon: Icons.speed_rounded,
            text:
                'Erster Scan mit vielen Videos dauert — Vorschaubilder '
                'werden im Hintergrund erzeugt, du kannst währenddessen '
                'ganz normal schauen.',
          ),
          const SizedBox(height: 10),
          _tipCard(
            icon: Icons.mouse_rounded,
            text:
                'Horizontale Leisten lassen sich per Mausrad, Maus-Drag '
                'oder Pfeil-Buttons bedienen. Die Pfeile erscheinen nur, '
                'wenn es tatsächlich was zu scrollen gibt.',
          ),
        ],
      ),
    );
  }

  // ─────────────────────────── Widgets ───────────────────────────

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
          const Icon(Icons.menu_book_rounded,
              color: AppTheme.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Komplette Funktionsübersicht der App. Für den Aufbau '
              'deines Medien-Ordners siehe „Ordner-Konvention" (eine '
              'Ebene höher in den Einstellungen).',
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

  Widget _featureCard({
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
          if (highlights.isNotEmpty) ...[
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
        ],
      ),
    );
  }

  Widget _shortcutsCard() {
    const rows = <List<String>>[
      ['Leertaste', 'Pause / Abspielen'],
      ['Doppelklick', 'Pause / Abspielen'],
      ['← / →', '10 Sekunden zurück / vor'],
      ['↑ / ↓', 'Lautstärke +5 % / −5 %'],
      ['M', 'Stummschalten'],
      ['F', 'Vollbild'],
      ['C  (auch S)', 'Untertitel ein/aus'],
      ['A', 'Nächste Audio-Spur'],
      ['P', 'Screenshot (nur mit Erw. Werkzeugen)'],
      ['1 / 2', 'Clip-Anfang / -Ende (nur mit Erw. Werkzeugen)'],
      ['Escape', 'Zurück zur Übersicht'],
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 16,
                thickness: 1,
                color: AppTheme.divider.withValues(alpha: 0.4),
              ),
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    rows[i][0],
                    style: const TextStyle(
                      color: AppTheme.accent,
                      fontFamily: 'Consolas, Courier New, monospace',
                      fontFamilyFallback: ['Consolas', 'Courier New', 'monospace'],
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    rows[i][1],
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ],
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
