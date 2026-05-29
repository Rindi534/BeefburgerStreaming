import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;
import 'package:path_provider/path_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/media_library_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/folder_validator.dart';
import '../services/thumbnail_service.dart';
import '../theme/app_theme.dart';
import '../widgets/thumbnail_config_section.dart';
import 'folder_convention_screen.dart';
import 'app_guide_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Cached thumbnail-cache size in bytes, refreshed on demand.
  Future<int>? _cacheSizeFuture;

  @override
  void initState() {
    super.initState();
    _refreshCacheSize();
  }

  void _refreshCacheSize() {
    setState(() {
      _cacheSizeFuture = ThumbnailService.instance.getCacheSize();
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const kb = 1024;
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (bytes < mb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / gb).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    // When a background thumbnail generation finishes, refresh the cache size
    // so the "currently used" hint stays accurate without manual tapping.
    ref.listen(mediaLibraryProvider, (prev, next) {
      if (prev?.isGeneratingThumbnails == true &&
          next.isGeneratingThumbnails == false) {
        _refreshCacheSize();
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Einstellungen'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Media folder section
          _buildSectionHeader(context, 'Medienbibliothek'),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.folder_rounded,
            title: 'Medien-Ordner',
            subtitle: settings.mediaFolderPath ?? 'Nicht ausgewählt',
            onTap: () => _selectMediaFolder(context, ref),
            // "Im Explorer öffnen" shortcut — only shown when a folder is
            // actually configured, otherwise there's nothing to open. The
            // whole tile's onTap still opens the picker so existing muscle
            // memory keeps working.
            trailingAction: settings.mediaFolderPath != null
                ? _FolderOpenAction(
                    path: settings.mediaFolderPath!,
                    tooltip: 'Medien-Ordner im Explorer öffnen',
                    onError: (msg) => _showFolderErrorDialog(context,
                        title: 'Ordner konnte nicht geöffnet werden',
                        message: msg),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          // Export folder is only meaningful with the advanced capture
          // features turned on — without them, there's nothing to export.
          // Render disabled/dimmed when advanced tools are off so the
          // cause-and-effect is visible rather than silently hiding the
          // whole tile.
          //
          // On iOS screenshot/clip export isn't supported (no FFmpeg in
          // the sandbox, and the native AVPlayer doesn't expose
          // frame/segment extraction we can route into a save-dialog),
          // so the whole tile is omitted to avoid a dead-end setting.
          if (!Platform.isIOS) ...[
            _buildSettingsTile(
              context,
              icon: Icons.ios_share_rounded,
              title: 'Export-Ordner',
              subtitle: !settings.advancedToolsEnabled
                  ? 'Nur verfügbar mit Erweiterten Werkzeugen'
                  : (settings.exportFolderPath ??
                      'Zielordner für Screenshots & Clips wählen'),
              onTap: settings.advancedToolsEnabled
                  ? () => _selectExportFolder(context, ref)
                  : () {},
              enabled: settings.advancedToolsEnabled,
              trailingAction: (settings.advancedToolsEnabled &&
                      settings.exportFolderPath != null)
                  ? _FolderOpenAction(
                      path: settings.exportFolderPath!,
                      tooltip: 'Export-Ordner im Explorer öffnen',
                      onError: (msg) => _showFolderErrorDialog(context,
                          title: 'Ordner konnte nicht geöffnet werden',
                          message: msg),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
          ],
          _buildSettingsTile(
            context,
            icon: Icons.refresh_rounded,
            title: 'Bibliothek aktualisieren',
            subtitle: 'Ordner erneut scannen',
            onTap: () {
              ref.read(mediaLibraryProvider.notifier).refresh();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Bibliothek wird aktualisiert...'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),

          const SizedBox(height: 32),

          // Playback section
          _buildSectionHeader(context, 'Wiedergabe'),
          const SizedBox(height: 12),
          _buildSwitchTile(
            context,
            icon: Icons.subtitles_rounded,
            title: 'Untertitel standardmäßig',
            subtitle: 'Untertitel beim Start aktivieren',
            value: settings.subtitlesEnabled,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setSubtitlesEnabled(v),
          ),
          const SizedBox(height: 8),
          // Sleep-Modus: alles spielt weiter inkl. Auto-Next, aber kein
          // Fortschritt landet im Continue-Watching-Box. Gedacht fürs
          // Einschlafen mit Serie — morgens ist der Stand noch der von
          // gestern Abend.
          _buildSwitchTile(
            context,
            icon: settings.sleepModeEnabled
                ? Icons.bedtime_rounded
                : Icons.bedtime_outlined,
            title: 'Sleep-Modus',
            subtitle: settings.sleepModeEnabled
                ? 'Aktiv — Folgen laufen weiter mit Auto-Next, aber dein Stand wird nicht aktualisiert'
                : 'Aus — Wiedergabe läuft normal weiter und der Stand wird wie üblich gespeichert',
            value: settings.sleepModeEnabled,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setSleepModeEnabled(v),
          ),
          const SizedBox(height: 8),
          // Advanced capture tools: unlocks screenshot + clip buttons,
          // their keyboard shortcuts (1/2/P), and the Export-Ordner
          // setting. Kept in the "Wiedergabe" section because turning it
          // on visibly changes the player chrome.
          //
          // Hidden on iOS — the native AVPlayerViewController doesn't
          // host custom Flutter chrome, and frame/segment export isn't
          // wired up there. The toggle would flip a flag no screen reads.
          if (!Platform.isIOS) ...[
            _buildSwitchTile(
              context,
              icon: Icons.tune_rounded,
              title: 'Erweiterte Werkzeuge',
              subtitle: settings.advancedToolsEnabled
                  ? 'Screenshot- und Clip-Buttons im Player aktiv'
                  : 'Zeigt Screenshot- und Clip-Buttons im Player an',
              value: settings.advancedToolsEnabled,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setAdvancedToolsEnabled(v),
            ),
            const SizedBox(height: 8),
          ],
          // Scrub-preview thumbnails rely on our own FFmpeg-generated
          // sprite cache — meaningless on iOS where AVPlayer renders its
          // own native scrub previews from the video's keyframes.
          if (!Platform.isIOS)
          _buildSwitchTile(
            context,
            icon: Icons.image_rounded,
            title: 'Vorschaubilder in der Seekleiste',
            subtitle: settings.thumbnailsEnabled
                ? 'Beim Hovern über die Zeitleiste wird eine Vorschau angezeigt'
                : 'Deaktiviert · keine Vorschaubilder werden erzeugt',
            value: settings.thumbnailsEnabled,
            onChanged: (v) async {
              await ref
                  .read(settingsProvider.notifier)
                  .setThumbnailsEnabled(v);
              if (v) {
                // Turning ON — regenerate by refreshing library
                if (context.mounted) {
                  ref.read(mediaLibraryProvider.notifier).refresh();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Vorschaubilder werden erstellt · Bibliothek wird aktualisiert'),
                      duration: Duration(seconds: 3),
                    ),
                  );
                }
              }
            },
          ),

          const SizedBox(height: 32),

          // Data section
          _buildSectionHeader(context, 'Daten'),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.delete_outline_rounded,
            title: 'Wiedergabeverlauf löschen',
            subtitle: 'Alle gespeicherten Positionen löschen',
            onTap: () => _confirmClearProgress(context, ref),
            textColor: AppTheme.accent,
          ),
          // Thumbnail cache only exists on desktop (FFmpeg-generated
          // scrub sprites). On iOS AVPlayer has no Flutter-side cache,
          // so there's nothing to display a size for — omit the tile
          // rather than show a confusing "0 B" permanently.
          if (!Platform.isIOS) ...[
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: _cacheSizeFuture,
              builder: (context, snapshot) {
                final subtitle = switch (snapshot.connectionState) {
                  ConnectionState.done when snapshot.hasData && snapshot.data! > 0 =>
                    'Aktuell belegt: ${_formatBytes(snapshot.data!)}',
                  ConnectionState.done => 'Cache ist leer',
                  _ => 'Größe wird berechnet…',
                };
                return _buildSettingsTile(
                  context,
                  icon: Icons.image_not_supported_rounded,
                  title: 'Vorschaubild-Cache leeren',
                  subtitle: subtitle,
                  onTap: () => _confirmClearThumbnails(context, ref),
                  textColor: AppTheme.accent,
                );
              },
            ),
          ],

          const SizedBox(height: 32),

          // Thumbnail / cache configuration section. Houses the
          // per-media keep-flags, the "Cache für entfernte Medien
          // behalten" global toggle, and the per-item reset tree —
          // all collapsible so the screen stays usable even with
          // dozens of items.
          //
          // Desktop-only for the same reason as the cache tile above —
          // iOS has no Flutter-managed thumbnail cache to configure.
          if (!Platform.isIOS) ...[
            _buildSectionHeader(context, 'Vorschaubilder-Konfig'),
            const SizedBox(height: 12),
            const ThumbnailConfigSection(),
            const SizedBox(height: 32),
          ],

          // Help / Documentation section
          _buildSectionHeader(context, 'Hilfe'),
          const SizedBox(height: 12),
          _buildSettingsTile(
            context,
            icon: Icons.menu_book_rounded,
            title: 'Ordner-Konvention',
            subtitle:
                'Wie der Medien-Ordner aufgebaut sein sollte · Namens­regeln',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const FolderConventionScreen(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildSettingsTile(
            context,
            icon: Icons.auto_stories_rounded,
            title: 'App-Anleitung',
            subtitle:
                'Komplette Funktionsübersicht · Player · Cache · Tastenkürzel',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AppGuideScreen(),
              ),
            ),
          ),

          const SizedBox(height: 44),

          // App info
          Center(
            child: Column(
              children: [
                Opacity(
                  opacity: 0.65,
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 56,
                    height: 56,
                    fit: BoxFit.contain,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'BeefburgerStreaming',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Version 1.5.7',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textMuted,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: AppTheme.accent,
            fontWeight: FontWeight.w700,
          ),
    );
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? textColor,
    // Optional action pinned to the trailing edge that fires WITHOUT
    // invoking the tile's main onTap. The whole row is still tappable
    // for the primary action (configure folder) — the trailing widget
    // just adds a secondary quick-action (open in Explorer) for the
    // case where the folder is already set up.
    _FolderOpenAction? trailingAction,
    // When false, the tile is rendered in a dimmed, non-interactive
    // state. Used for settings that depend on another toggle (e.g.
    // Export-Ordner only makes sense with advanced tools enabled).
    bool enabled = true,
  }) {
    final effectiveTextColor = enabled
        ? (textColor ?? AppTheme.textPrimary)
        : AppTheme.textMuted.withValues(alpha: 0.5);
    final effectiveSubtitleColor = enabled
        ? AppTheme.textMuted
        : AppTheme.textMuted.withValues(alpha: 0.4);
    // When a trailing action is attached, we render the tile as a
    // split-button: the wider left half runs the primary `onTap` (pick
    // folder), the right half runs the secondary action (open in
    // Explorer). Both halves have their own InkWell, separated by a
    // visible divider so it reads as two clickable regions — the old
    // version hid the "open" action in a 32 px icon that was easy to
    // miss. The non-split form (no trailing action) keeps the original
    // single-InkWell layout so every other settings tile is unchanged.
    final leftContent = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight.withValues(
                  alpha: enabled ? 1.0 : 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: effectiveTextColor, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: effectiveTextColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: effectiveSubtitleColor,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailingAction == null)
            Icon(Icons.chevron_right_rounded,
                color: effectiveSubtitleColor),
        ],
      ),
    );

    if (trailingAction == null) {
      return Material(
        color:
            AppTheme.surface.withValues(alpha: enabled ? 1.0 : 0.5),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          // Passing null disables the InkWell entirely — no ripple, no
          // cursor change — which is exactly what "disabled" should look
          // like for a tappable tile.
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: leftContent,
        ),
      );
    }

    // Split-button layout. Outer radius stays on the Material; inner
    // InkWells clip to the left/right halves.
    return Material(
      color:
          AppTheme.surface.withValues(alpha: enabled ? 1.0 : 0.5),
      borderRadius: BorderRadius.circular(12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: enabled ? onTap : null,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
              child: leftContent,
            ),
          ),
          Container(
            width: 1,
            height: 56,
            color: AppTheme.surfaceLight.withValues(
                alpha: enabled ? 1.0 : 0.5),
          ),
          trailingAction,
        ],
      ),
    );
  }

  Widget _buildSwitchTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppTheme.textPrimary, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppTheme.accent,
            activeTrackColor: AppTheme.accent.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }

  /// Wraps `FilePicker.getDirectoryPath` with:
  /// - a try/catch so a picker-side exception can't crash the whole app
  ///   (known crashes on some Windows + cloud-drive combinations)
  /// - a post-pick validation (cloud folder / vanished drive) with a
  ///   user-facing dialog explaining what went wrong, rather than silently
  ///   accepting a path that will later explode in the middle of a scan.
  Future<String?> _pickFolder(BuildContext context, String dialogTitle) async {
    // iOS: apps are sandboxed, there's no "pick any folder anywhere"
    // dialog. Instead we always use the app's Documents directory —
    // which is exposed to the user via Files → On My iPad →
    // BeefburgerStreaming thanks to UIFileSharingEnabled. The user
    // drops their media in there and everything works.
    //
    // We skip the picker UI entirely and just return the Documents
    // path. The caller still runs validation, so a missing/unwritable
    // directory gets the normal error dialog.
    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      final docsPath = docs.path;
      if (!context.mounted) return null;
      await _showFolderErrorDialog(
        context,
        title: 'Medien-Ordner auf iPad',
        message:
            'Auf iPad benutzt BeefburgerStreaming einen festen Ordner:\n\n'
            '$docsPath\n\n'
            'Öffne die Dateien-App → „Auf meinem iPad" → '
            '„BeefburgerStreaming" und lege deine Videos, Serien-'
            'Ordner und Cover dort ab. Nach dem Schließen dieses '
            'Hinweises startet der Scan automatisch.',
      );
      return docsPath;
    }

    String? picked;
    try {
      picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: dialogTitle,
      );
    } catch (e) {
      if (!context.mounted) return null;
      await _showFolderErrorDialog(
        context,
        title: 'Ordnerauswahl fehlgeschlagen',
        message:
            'Beim Öffnen des Auswahldialogs ist ein Fehler aufgetreten:\n$e\n\n'
            'Das passiert manchmal bei Cloud-synchronisierten Ordnern '
            '(OneDrive, Dropbox, iCloud, …). Bitte einen lokalen Ordner '
            'wählen.',
      );
      return null;
    }

    if (picked == null) return null; // user cancelled

    final error = FolderValidator.validate(picked);
    if (error != null) {
      if (context.mounted) {
        await _showFolderErrorDialog(
          context,
          title: 'Ordner nicht unterstützt',
          message: error,
        );
      }
      return null;
    }
    return picked;
  }

  Future<void> _showFolderErrorDialog(
    BuildContext context, {
    required String title,
    required String message,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title,
            style: const TextStyle(color: AppTheme.textPrimary)),
        content: Text(message,
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _selectMediaFolder(BuildContext context, WidgetRef ref) async {
    final path = await _pickFolder(context, 'Medien-Ordner auswählen');
    if (path == null) return;
    await ref.read(settingsProvider.notifier).setMediaFolderPath(path);
    await ref.read(mediaLibraryProvider.notifier).scanLibrary(path);
  }

  Future<void> _selectExportFolder(BuildContext context, WidgetRef ref) async {
    final path = await _pickFolder(context, 'Export-Ordner auswählen');
    if (path == null) return;
    await ref.read(settingsProvider.notifier).setExportFolderPath(path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export-Ordner gesetzt:\n$path'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _confirmClearProgress(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Verlauf löschen?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Alle gespeicherten Wiedergabe-Positionen werden gelöscht. Dies kann nicht rückgängig gemacht werden.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () {
              ref.read(watchProgressProvider.notifier).clearAll();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Verlauf gelöscht'),
                ),
              );
            },
            child: const Text('Löschen',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }

  void _confirmClearThumbnails(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Vorschaubild-Cache leeren?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Alle zwischengespeicherten Seekbar-Vorschaubilder werden gelöscht. '
          'Sie werden bei der nächsten Bibliotheksaktualisierung neu erstellt '
          '(sofern aktiviert).',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Abbrechen',
                style: TextStyle(color: AppTheme.textMuted)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ThumbnailService.instance.clearCache();
              if (mounted) _refreshCacheSize();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Vorschaubild-Cache geleert'),
                  ),
                );
              }
            },
            child: const Text('Löschen',
                style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }
}

/// Secondary action shown at the trailing edge of a folder-configuration
/// tile: opens the configured path in the system file explorer.
///
/// Split into its own widget so the InkWell's tap surface is strictly
/// limited to the small square around the icon — users can still tap
/// the rest of the tile to re-configure the folder. Uses
/// `GestureDetector` + `HitTestBehavior.opaque` to block the parent
/// InkWell's ripple from firing through, so a single tap never triggers
/// both "open explorer" AND "open picker" by accident.
class _FolderOpenAction extends StatelessWidget {
  final String path;
  final String tooltip;
  final void Function(String message) onError;

  const _FolderOpenAction({
    required this.path,
    required this.tooltip,
    required this.onError,
  });

  Future<void> _open() async {
    // Quick existence check so we can give the user a clean error if the
    // drive vanished, rather than silently launching an empty Explorer.
    if (!await Directory(path).exists()) {
      onError('Der Ordner existiert nicht (mehr):\n$path');
      return;
    }
    try {
      if (Platform.isIOS) {
        // iOS can't shell out. Open the Files app at the app's
        // Documents folder (which is where media lives in the iOS
        // build) via the documented shareddocuments:// scheme.
        final uri = Uri.parse('shareddocuments://$path');
        final ok = await url_launcher.launchUrl(uri);
        if (!ok) {
          onError(
              'Die Dateien-App konnte nicht geöffnet werden. Öffne '
              'sie manuell und navigiere zu „Auf meinem iPad → '
              'BeefburgerStreaming".');
        }
      } else if (Platform.isWindows) {
        // `explorer` returns exit-code 1 even on success, so we do NOT
        // check exitCode — just detach the process and move on.
        await Process.start('explorer', [path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path],
            mode: ProcessStartMode.detached);
      } else {
        // Linux / *BSD: xdg-open is the least-bad cross-distro option.
        await Process.start('xdg-open', [path],
            mode: ProcessStartMode.detached);
      }
    } catch (e) {
      onError('Konnte den Datei-Explorer nicht starten:\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Right half of the split-button. Large-ish hit area (icon + label,
    // generous padding) so it reads as a proper second button rather
    // than a decorative glyph. InkWell gives ripple feedback matching
    // the left half. No `behavior: opaque` needed here — the split
    // layout means we're not overlaying a parent InkWell any more.
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: _open,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(12),
          bottomRight: Radius.circular(12),
        ),
        child: SizedBox(
          // Roughly 2× the previous width so the button reads as a full
          // secondary action rather than a narrow trailing icon. Fixed
          // width (not padding) so both tiles align identically even if
          // one has a shorter label than the other.
          width: 96,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(
                  Icons.open_in_new_rounded,
                  color: AppTheme.textSecondary,
                  size: 22,
                ),
                SizedBox(height: 4),
                Text(
                  'Öffnen',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
