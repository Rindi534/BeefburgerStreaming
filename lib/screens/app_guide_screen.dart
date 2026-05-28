import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// In-app guide covering every feature of the iOS app. Paired with
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
                'Oben: Logo, Suchleiste, Aktualisieren- und '
                'Einstellungs-Button. Darunter — sobald du etwas '
                'angefangen hast — die „Weiterschauen"-Leiste, danach '
                'das vollständige Raster.',
            highlights: const [
              'Jede Kachel zeigt das Cover-Bild',
              'Fehlt ein Cover, wird ein Auto-Frame aus dem Video genutzt',
              'Tipp auf eine Kachel → Detail-Ansicht',
              'Wisch von oben nach unten über das Raster → aktualisieren',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.search_rounded,
            title: 'Suchleiste',
            description:
                'Im Kopfbereich der Startseite. Tippe los — es wird live '
                'gefiltert, ein Dropdown mit den Treffern erscheint direkt '
                'darunter. Gruppen: Filme, Serien, Folgen.',
            highlights: const [
              'Film antippen → startet direkt im Player',
              'Serie antippen → öffnet die Detail-Ansicht',
              'Folge antippen → spielt die Folge sofort — die '
                  'nächste Folge wird automatisch angehängt und die '
                  'Position wird gemerkt',
              'Filme und Serien erscheinen mit ihrem Hochformat-Cover, '
                  'Folgen mit einem Querformat-Vorschaubild',
              'Treffer am Wortanfang werden zuerst gezeigt',
              'Tipp außerhalb oder die iOS-Tastatur schließen → Dropdown zu',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.history_rounded,
            title: 'Weiterschauen-Leiste',
            description:
                'Horizontale Reihe mit angefangenen Folgen und Filmen. '
                'Ab 90 % Fortschritt gilt etwas als „fertig" und '
                'verschwindet automatisch aus der Leiste.',
            highlights: const [
              'Horizontal wischen, um durchzublättern',
              'Fortschrittsbalken unter jeder Karte',
              'Bild: thumbnail.jpg bevorzugt (16:9), sonst banner/cover',
              'Tipp auf eine Karte → spielt direkt an der letzten Position weiter',
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
              'Staffel-Leiste: horizontal wischen',
              'Tipp auf Episode öffnet den Player mit letzter Position',
              'Pfeil oben links → zurück',
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
                'Die Steuerleiste blendet sich nach ein paar Sekunden ohne '
                'Berührung aus. Einmal tippen blendet sie sofort wieder ein. '
                'Die Position wird automatisch gespeichert.',
            highlights: const [
              'Einmal tippen: Steuerleiste ein/aus',
              'Doppel-Tap: Pause / Abspielen',
              'Doppel-Tap links/rechts: 10 Sek zurück/vor',
              'Seekleiste antippen oder ziehen: Position wählen',
              'Lautstärke/Helligkeit: über die normalen iOS-Tasten / das Kontrollzentrum',
              'Pfeil oben links: zurück (Position wird gemerkt)',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.picture_in_picture_alt_rounded,
            title: 'Bild-im-Bild (PiP)',
            description:
                'Der iOS-Player unterstützt vollständig die Picture-in-'
                'Picture-Funktion von iOS. Du kannst das Video aus der '
                'App in ein kleines, frei verschiebbares Fenster '
                'auslagern und währenddessen Mails lesen, im Netz '
                'surfen oder andere Apps benutzen.',
            highlights: const [
              'PiP-Button in der Steuerleiste → manuell starten',
              'Home/Sperrtaste während der Wiedergabe → automatisch in PiP wechseln',
              'PiP-Fenster: Tap-and-Hold → ziehen · Ecken anfassen → Größe',
              'Im PiP-Fenster: Play/Pause, ±15 Sek und Vor/Zurück (nächste Folge)',
              'Tipp auf das PiP-Fenster → zurück in die App',
              'Am Ende der Folge startet im PiP automatisch die nächste',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.lock_clock_rounded,
            title: 'Sperrbildschirm & Kontrollzentrum',
            description:
                'Während der Wiedergabe erscheint die Folge ganz normal '
                'als „Wird wiedergegeben"-Karte auf dem Sperrbildschirm '
                'und im iOS-Kontrollzentrum — mit Cover, Titel, '
                'Fortschritt und Steuerung.',
            highlights: const [
              'Play / Pause direkt vom Sperrbildschirm',
              '±15 Sekunden Skip-Buttons',
              'Vor/Zurück-Tasten springen zur nächsten/vorherigen Folge',
              'Fortschrittsbalken zum Scrubben',
              'Funktioniert auch mit AirPods / Bluetooth-Kopfhörern',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.subtitles_rounded,
            title: 'Untertitel',
            description:
                'Eingebettete Untertitel in .mkv werden automatisch '
                'erkannt — auch SSA/ASS und mehrsprachige Spuren. '
                'Externe .srt-Dateien mit dem gleichen Namen wie das '
                'Video werden zusätzlich angeboten.',
            highlights: const [
              'Untertitel-Button im Player öffnet das Auswahl-Menü',
              'Mehrere Spuren? Einfach antippen, sofortiger Wechsel',
              'Auch deaktivierbar („Aus")',
              'Standard-Verhalten konfigurierbar in den Einstellungen',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.audiotrack_rounded,
            title: 'Audio-Spuren',
            description:
                'Bei Videos mit mehreren Tonspuren (z. B. Deutsch + '
                'Englisch) erscheint das Musiknoten-Symbol in der '
                'Steuerleiste. Tipp drauf → Sprache wählen.',
            highlights: const [
              'Aktive Spur ist farbig markiert',
              'Wechsel ohne Neustart der Wiedergabe',
            ],
          ),
          const SizedBox(height: 12),
          _featureCard(
            icon: Icons.skip_next_rounded,
            title: 'Auto-Play nächste Episode',
            description:
                'Am Ende einer Folge erscheint ein 10-Sekunden-Countdown '
                'mit Vorschau der nächsten Episode aus dem gleichen '
                'Staffel-Ordner. Funktioniert auch im PiP-Modus.',
            highlights: const [
              '„Jetzt starten": überspringt Countdown',
              '„Abbrechen": Countdown stoppen',
              'Nächste Folge = nächstgrößere Episoden-Nummer im Ordner',
              'Im PiP läuft die nächste Folge ohne weiteres Zutun weiter',
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
                'Nach jeder Änderung in deinem BeefburgerStreaming-Ordner '
                '(neuer Film über die Dateien-App hinzugefügt, Folge '
                'gelöscht, Datei umbenannt) tippst du oben rechts auf '
                'das Aktualisieren-Symbol. Die App vergleicht den Ordner '
                'mit ihrem letzten Stand und zeigt dir in einem Dialog, '
                'was sich geändert hat.',
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
                'Schild-Symbol. Tipp drauf, und die App merkt sich '
                'diesen Eintrag. Das heißt: Selbst wenn du die Datei '
                'irgendwann vom iPhone löschst (z. B. zum '
                'Speicherplatz-Sparen), bleibt das Vorschaubild in '
                'der App erhalten und der Eintrag rutscht ins Archiv '
                'statt einfach zu verschwinden.',
            highlights: const [
              'Sinnvoll für Lieblingsfilme oder -serien, die du immer '
                  'wieder mal zwischendurch vom iPhone räumst',
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
                'Datei gerade nicht im BeefburgerStreaming-Ordner liegt. '
                'Solange ein Eintrag im Archiv liegt, bleibt sein '
                'Cover/Vorschaubild erhalten. Lädst du die Datei wieder '
                'in den Ordner und aktualisierst die Bibliothek, taucht '
                'der Eintrag automatisch wieder normal auf.',
            highlights: const [
              'Mülleimer-Symbol: endgültig aus der App entfernen',
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
                'Tipp auf einen Eintrag markiert ihn zum Neu-Erzeugen. '
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
              'Nützlich z. B. wenn du Speicherplatz auf dem iPhone '
                  'freimachen willst',
            ],
          ),

          const SizedBox(height: 28),
          _sectionTitle(context, 'Gut zu wissen'),
          const SizedBox(height: 12),
          _tipCard(
            icon: Icons.lock_rounded,
            text:
                'Alles bleibt lokal auf deinem iPhone/iPad. Keine '
                'Uploads, kein Account, kein Internet nötig.',
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
            icon: Icons.swipe_rounded,
            text:
                'Horizontale Leisten (Weiterschauen, Staffeln) lassen '
                'sich einfach mit dem Finger durchwischen.',
          ),
          const SizedBox(height: 10),
          _tipCard(
            icon: Icons.headphones_rounded,
            text:
                'Per AirPlay kannst du das Audio auf einen kompatiblen '
                'Lautsprecher oder Apple TV streamen — die '
                'Wiedergabe-Steuerung bleibt am iPhone.',
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
              'Komplette Funktionsübersicht für die iPhone/iPad-App. '
              'Wie du deine Videos aufs iPhone bekommst und den Ordner '
              'aufbaust, steht unter „Ordner-Konvention" (eine Ebene '
              'höher in den Einstellungen).',
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
