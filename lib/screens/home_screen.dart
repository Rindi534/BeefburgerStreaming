import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/media_item.dart';
import '../models/episode.dart';
import '../models/watch_progress.dart';
import '../providers/media_library_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/settings_provider.dart';
import '../widgets/cache_changes_dialog.dart';
import '../widgets/media_card.dart';
import '../widgets/continue_watching.dart';
import '../widgets/global_search.dart';
import '../theme/app_theme.dart';
import 'detail_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // iOS-Status-Bar absichern: der Player räumt seine
    // immersive-Mode auf, aber wenn der User per Edge-Swipe-Pop
    // zurückkommt kann der Restore zu spät landen. Wir setzen
    // hier nochmal explizit auf "alle Overlays sichtbar" sobald
    // der HomeScreen gemountet wird.
    _ensureSystemUIVisible();
    // Guaranteed fresh scan on every app start.
    //
    // The MediaLibraryNotifier also kicks off a scan in its own `_init`, but
    // that only fires the first time the provider is constructed. Triggering
    // refresh() explicitly here means new files the user added to the media
    // folder while the app was closed show up (and get their thumbnails
    // generated) without the user having to press "Aktualisieren".
    //
    // Safe against double-scans: `scanLibrary` early-returns if a scan is
    // already running, so if `_init` fired milliseconds earlier this is a
    // no-op.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = ref.read(settingsProvider);
      if (settings.mediaFolderPath != null) {
        ref.read(mediaLibraryProvider.notifier).refresh();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App returned to foreground → re-assert visible Status-Bar.
  /// Sicherheitsnetz für den Fall dass iOS während des Backgrounds
  /// (oder beim Zurückkommen aus dem PiP-Sleep) den Mode geändert
  /// hat. setEnabledSystemUIMode ist idempotent und billig.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ensureSystemUIVisible();
    }
  }

  void _ensureSystemUIVisible() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(mediaLibraryProvider);
    final continueWatching = ref.watch(continueWatchingProvider);
    final settings = ref.watch(settingsProvider);

    // Surface structural-change detections from the scanner as a modal
    // dialog. Only fires when pendingChanges goes from empty to
    // non-empty so we don't re-open the dialog on every rebuild.
    ref.listen(mediaLibraryProvider, (prev, next) {
      final hadChanges = prev?.pendingChanges.isNotEmpty ?? false;
      final hasChanges = next.pendingChanges.isNotEmpty;
      if (!hadChanges && hasChanges) {
        // Post-frame so the dialog can find a valid Navigator context
        // even if this fires during the very first build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          showCacheChangesDialog(context, ref, next.pendingChanges);
        });
      }
    });

    // Surface non-fatal thumbnail warnings (disk full, cache unwritable,
    // repeated ffmpeg failures) as a snackbar. The library still loads
    // normally — only thumbnail generation is affected.
    ref.listen(mediaLibraryProvider, (prev, next) {
      final warning = next.thumbnailWarning;
      if (warning != null && warning != prev?.thumbnailWarning) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.clearSnackBars();
        messenger?.showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: AppTheme.accent, size: 22),
                const SizedBox(width: 12),
                Expanded(child: Text(warning)),
              ],
            ),
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'OK',
              textColor: AppTheme.accent,
              onPressed: () {
                ref
                    .read(mediaLibraryProvider.notifier)
                    .dismissThumbnailWarning();
              },
            ),
          ),
        );
      }
    });

    if (settings.mediaFolderPath == null) {
      return _buildSetupScreen(context, ref);
    }

    return Scaffold(
      body: SafeArea(
        child: library.isLoading
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.accent),
              )
            : library.error != null
                ? _buildErrorState(context, ref, library.error!)
                : library.items.isEmpty
                    ? _buildEmptyState(context, ref)
                    : _buildLibrary(context, ref, library, continueWatching),
      ),
      // Dezenter persistenter Hinweis im Footer, wenn Sleep-Modus
      // gerade aktiv ist. Bewusst NICHT als Banner ganz oben (zu
      // präsent) sondern als schmaler Streifen unten am Rand —
      // sichtbar genug dass man's beim Aufwachen sofort sieht und
      // nicht überrascht ist warum Continue-Watching „stehen
      // geblieben" ist.
      bottomNavigationBar: settings.sleepModeEnabled
          ? const _SleepModeFooter()
          : null,
    );
  }

  Widget _buildSetupScreen(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/logo_wide.png',
              width: 480,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 12),
            Text(
              'Deine lokale Streaming-Plattform',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppTheme.textMuted,
                    letterSpacing: 0.3,
                  ),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('Medien-Ordner auswählen'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibrary(
    BuildContext context,
    WidgetRef ref,
    MediaLibraryState library,
    List<WatchProgress> continueWatching,
  ) {
    // Phone-portrait breakpoint. Below this the logo + wide search +
    // two icon buttons overflow horizontally; we split them into two
    // rows: compact header (smaller logo + action icons) on top, full-
    // width search bar in the AppBar's `bottom` slot underneath.
    final narrow = MediaQuery.of(context).size.width < 500;

    return CustomScrollView(
      slivers: [
        // App Bar
        SliverAppBar(
          floating: true,
          // Taller toolbar so the larger logo has breathing room and the
          // action icons scale up proportionally without looking cramped.
          // On narrow phones we shrink to avoid eating half the screen.
          toolbarHeight: narrow ? 60 : 78,
          titleSpacing: narrow ? 12 : 20,
          // Logo + global search field. On wide screens both live in one
          // row (search Expanded between logo and actions). On narrow
          // phones the search moves into `bottom:` so the top row has
          // breathing room for logo + the two action icons.
          title: narrow
              ? Image.asset(
                  'assets/images/logo_wide.png',
                  height: 38,
                  fit: BoxFit.contain,
                )
              : Row(
                  children: [
                    Image.asset(
                      'assets/images/logo_wide.png',
                      height: 58,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(width: 24),
                    const Expanded(child: GlobalSearchField()),
                    const SizedBox(width: 16),
                  ],
                ),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh_rounded, size: narrow ? 24 : 28),
              onPressed: () =>
                  ref.read(mediaLibraryProvider.notifier).refresh(),
              tooltip: 'Bibliothek aktualisieren',
            ),
            IconButton(
              icon: Icon(Icons.settings_rounded, size: narrow ? 24 : 28),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              tooltip: 'Einstellungen',
            ),
            SizedBox(width: narrow ? 6 : 12),
          ],
          // Second row: full-width search on narrow phones. Null on
          // desktop/tablet — the search lives inline in `title`.
          bottom: narrow
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(56),
                  child: Padding(
                    padding:
                        const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: const GlobalSearchField(),
                  ),
                )
              : null,
        ),

        // Thumbnail generation progress banner
        if (library.isGeneratingThumbnails)
          SliverToBoxAdapter(
            child: _buildThumbnailProgressBanner(library),
          ),

        // FFmpeg missing banner
        if (library.ffmpegMissing && !library.isGeneratingThumbnails)
          SliverToBoxAdapter(
            child: _buildFFmpegMissingBanner(context),
          ),

        // Continue Watching
        if (continueWatching.isNotEmpty)
          SliverToBoxAdapter(
            child: ContinueWatchingSection(
              items: continueWatching,
              imageResolver: (id) {
                // Pull the three possible image paths for this media from
                // the live library so the card can pick the best available
                // (thumbnail → banner → cover → WatchProgress snapshot).
                // Returns all-null for removed media so the card falls back
                // to the cover snapshot stored in the WatchProgress record.
                //
                // Der iOS-VLC-Player mutiert bei Episoden-Wechsel die
                // `mediaId` zu `<serienId>::<episodePath>` (damit Watch-
                // Progress pro Episode gespeichert wird). Für den Image-
                // Lookup interessiert uns aber nur die Serie → Präfix
                // vor `::` abschneiden. Sonst matcht der `item.id`-
                // Vergleich nicht und Thumbnail/Banner/Cover fallen auf
                // den (oft veralteten) WatchProgress-Snapshot zurück —
                // genau das war der Thumbnail-Hiccup nach Next-Episode.
                final idx = id.indexOf('::');
                final lookupId = idx > 0 ? id.substring(0, idx) : id;
                for (final item in library.items) {
                  if (item.id == lookupId) {
                    return (
                      thumbnail: item.thumbnailImagePath,
                      banner: item.bannerImagePath,
                      cover: item.coverImagePath,
                    );
                  }
                }
                return (thumbnail: null, banner: null, cover: null);
              },
              onTap: (progress) {
                _playContinueWatching(context, ref, library, progress);
              },
            ),
          ),

        // Series section
        if (library.series.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Serien',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ),
          _buildMediaGrid(context, ref, library.series),
        ],

        // Movies section
        if (library.movies.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Filme',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ),
          _buildMediaGrid(context, ref, library.movies),
        ],

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: 40)),
      ],
    );
  }

  Widget _buildThumbnailProgressBanner(MediaLibraryState library) {
    final progress = library.thumbnailsTotal > 0
        ? library.thumbnailsCurrent / library.thumbnailsTotal
        : 0.0;
    final notifier = ref.read(mediaLibraryProvider.notifier);
    final isCancelling = notifier.isCancellingThumbnails;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isCancelling
                      ? 'Wird beendet · aktuelle Datei wird fertiggestellt…'
                      : 'Vorschaubilder werden erstellt · ${library.thumbnailsCurrent}/${library.thumbnailsTotal}',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Stop button. Disabled visually while a cancel is
              // already in flight so users don't spam it expecting
              // the ffmpeg process to keel over faster — it stops at
              // the next file boundary regardless.
              TextButton.icon(
                onPressed: isCancelling
                    ? null
                    : () {
                        notifier.cancelThumbnailGeneration();
                        // Force a repaint so the label swaps to
                        // "Wird beendet…" immediately instead of
                        // waiting for the next state emission from
                        // the notifier.
                        setState(() {});
                      },
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: const Text('Stopp'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                ),
              ),
            ],
          ),
          if (library.currentThumbnailLabel != null) ...[
            const SizedBox(height: 6),
            Text(
              library.currentThumbnailLabel!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ],
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: AppTheme.progressBackground,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppTheme.accent),
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFFmpegMissingBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.textMuted.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              color: AppTheme.textSecondary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FFmpeg nicht gefunden',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Für Vorschaubilder in der Seek-Leiste FFmpeg installieren (ffmpeg.exe neben der App oder im PATH).',
                  style: TextStyle(
                    color: AppTheme.textMuted.withValues(alpha: 0.9),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaGrid(
    BuildContext context,
    WidgetRef ref,
    List<MediaItem> items,
  ) {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth > 1200
        ? 6
        : screenWidth > 900
            ? 5
            : screenWidth > 600
                ? 4
                : screenWidth > 400
                    ? 3
                    : 2;

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 0.65,
          crossAxisSpacing: 16,
          mainAxisSpacing: 20,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];
            return MediaCard(
              item: item,
              onTap: () => _onMediaTap(context, ref, item),
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }

  void _playContinueWatching(
    BuildContext context,
    WidgetRef ref,
    MediaLibraryState library,
    WatchProgress progress,
  ) {
    // Try to find the MediaItem in the library to get full episode info
    MediaItem? mediaItem;
    for (final item in library.items) {
      if (item.id == progress.mediaId) {
        mediaItem = item;
        break;
      }
      // Also check by filePath match in episodes
      for (final ep in item.allEpisodes) {
        if (ep.filePath == progress.filePath) {
          mediaItem = item;
          break;
        }
      }
      if (mediaItem != null) break;
      // Check movie filePath
      if (item.movieFilePath == progress.filePath) {
        mediaItem = item;
        break;
      }
    }

    if (mediaItem != null && mediaItem.type == MediaType.series) {
      // Found the series — get full episode list and next episode info
      final allEpisodes = mediaItem.allEpisodes;
      final currentIndex =
          allEpisodes.indexWhere((e) => e.filePath == progress.filePath);

      Episode? nextEpisode;
      if (currentIndex >= 0 && currentIndex < allEpisodes.length - 1) {
        nextEpisode = allEpisodes[currentIndex + 1];
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            filePath: progress.filePath,
            title: mediaItem!.title,
            episodeTitle: progress.episodeTitle,
            mediaId: mediaItem.id,
            coverImagePath: mediaItem.coverImagePath,
            startPosition: progress.position,
            nextEpisodeFilePath: nextEpisode?.filePath,
            nextEpisodeTitle: nextEpisode?.fullDisplayName,
            nextEpisodeSubtitlePath: nextEpisode?.subtitlePath,
            allEpisodes: allEpisodes,
            currentEpisodeIndex: currentIndex >= 0 ? currentIndex : 0,
          ),
        ),
      );
    } else {
      // Movie or unknown — simple launch
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            filePath: progress.filePath,
            title: progress.mediaTitle ?? 'Video',
            mediaId: progress.mediaId,
            coverImagePath: progress.coverImagePath ?? mediaItem?.coverImagePath,
            startPosition: progress.position,
          ),
        ),
      );
    }
  }

  void _onMediaTap(BuildContext context, WidgetRef ref, MediaItem item) {
    if (item.type == MediaType.movie && item.movieFilePath != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            filePath: item.movieFilePath!,
            title: item.title,
            mediaId: item.id,
            coverImagePath: item.coverImagePath,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DetailScreen(mediaItem: item),
        ),
      );
    }
  }

  Widget _buildErrorState(BuildContext context, WidgetRef ref, String error) {
    // Explicit foreground colors are required on this screen: without
    // them the platform default for ElevatedButton is a dark-on-dark
    // combination that leaves the button looking like a blank red pill.
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 64, color: AppTheme.accent),
            const SizedBox(height: 16),
            Text(
              error,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: () =>
                      ref.read(mediaLibraryProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Erneut versuchen'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: Colors.white,
                  ),
                ),
                // Always offer a route to Settings from this screen —
                // when the stored media folder is gone (moved/unmounted
                // drive), "Erneut versuchen" re-runs the same failing
                // scan and leaves the user stuck. Picking a new folder
                // is the only real escape.
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SettingsScreen()),
                  ),
                  icon: const Icon(Icons.settings_rounded),
                  label: const Text('Einstellungen'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: AppTheme.textMuted),
                  ),
                ),
                // iOS escape hatch: when the container UUID rotates
                // (reinstall / re-sign), the stored absolute path is
                // dead. This button force-resets the media folder to
                // the current Documents dir, which is the only valid
                // location on iOS anyway.
                if (Platform.isIOS)
                  OutlinedButton.icon(
                    onPressed: () async {
                      final docs =
                          await getApplicationDocumentsDirectory();
                      await ref
                          .read(settingsProvider.notifier)
                          .setMediaFolderPath(docs.path);
                      await ref
                          .read(mediaLibraryProvider.notifier)
                          .refresh();
                    },
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Dateien-Ordner verwenden'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppTheme.textMuted),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_open_rounded,
              size: 64, color: AppTheme.textMuted),
          const SizedBox(height: 16),
          Text(
            'Keine Videos gefunden',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Lege Video-Dateien in den ausgewählten Ordner',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(mediaLibraryProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Aktualisieren'),
                // foregroundColor explizit setzen — sonst nimmt der
                // Button die Default-Foreground-Color des dunklen
                // Themes (≈ schwarz auf rot, schaut aus wie ein
                // leerer Pill ohne Schrift). Symptom v1.5.30: User-
                // Bugreport zeigte den roten Button text-/iconlos.
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SettingsScreen()),
                ),
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Einstellungen'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Persistenter, ästhetischer Hinweis am Bildschirmrand wenn der
/// Sleep-Modus gerade aktiv ist.
///
/// Layout-Logik:
///  - Icon + Status-Text werden in der Mitte des Footers gruppiert
///    (zentriert über die volle Breite, NICHT links-anliegend).
///  - Der "Ausschalten"-Pill sitzt als eigenständig anklickbarer
///    Akzent-Button rechts daneben — der gesamte Footer ist NICHT
///    mehr tappable, weil der dedizierte Button die Aktion klarer
///    kommuniziert als ein riesiger Tap-Bereich der die ganze
///    Leiste umfasst.
///  - Auf schmalen Devices (iPhone, < 600 dp Shortest-Side) wird
///    nur "Sleep-Modus aktiv" angezeigt; der "Fortschritt wird
///    nicht gespeichert"-Zusatz nur auf iPad und breiter.
class _SleepModeFooter extends StatelessWidget {
  const _SleepModeFooter();

  @override
  Widget build(BuildContext context) {
    // 600 dp shortestSide ist die kanonische iPhone/iPad-Grenze
    // (Apple HIG + Flutter material breakpoints).
    final isCompact = MediaQuery.of(context).size.shortestSide < 600;
    final statusText = isCompact
        ? 'Sleep-Modus aktiv'
        : 'Sleep-Modus aktiv · Fortschritt wird nicht gespeichert';

    return Material(
      color: AppTheme.accent.withValues(alpha: 0.12),
      child: SafeArea(
        top: false,
        child: Container(
          // Schlanke 6 px vertikal — der Container schrumpft auf die
          // natürliche Höhe seiner Row, die ihrerseits vom Pill-
          // Button (~28 px) dominiert wird. Vorher 10 px war
          // unnötig wuchtig.
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: AppTheme.accent, width: 1),
            ),
          ),
          // Eine einzige Row mit mainAxisAlignment.center —
          // Mond + Text + Pille wandern als kompakte Gruppe in
          // die Bildschirmmitte mit fixen ästhetischen Abständen
          // (10/12 px). Horizontal: durch mainAxisAlignment.center.
          // Vertikal: durch Container-padding gepaart mit
          // crossAxisAlignment.center (Default) auf der Row.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              const Icon(Icons.bedtime_rounded,
                  color: AppTheme.accent, size: 17),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  statusText,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              const SizedBox(width: 12),
              _OffPillButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Schlanke, ästhetische Akzent-Pille. Visuell ein eigenständiger
/// Button, kein nackter Text-Link — die volle Akzentfläche samt
/// rundem Border macht klar dass das ein echtes UI-Control ist
/// das man tappen kann.
class _OffPillButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _OffPillButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.accent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: const Padding(
          padding: EdgeInsets.fromLTRB(10, 5, 7, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Ausschalten',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              SizedBox(width: 1),
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
