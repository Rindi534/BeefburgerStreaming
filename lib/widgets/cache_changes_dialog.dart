import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/media_history_provider.dart';
import '../providers/media_library_provider.dart';
import '../theme/app_theme.dart';

/// Dialog shown after a library scan when the media folder's structure
/// has changed since the last known snapshot. Three kinds of change,
/// each with its own icon + checkbox semantics:
///
///  - ⊕ added     → "Vorschaubilder jetzt erstellen" (default ON)
///  - ⚠ modified  → "Vorschaubilder neu erstellen"   (default ON)
///  - ⊖ removed   → "Cache für diese Datei löschen"  (default OFF)
///
/// The dialog DEFERS all cache work until the user confirms:
/// thumbnail generation is paused while it's open (see
/// [MediaLibraryNotifier.scanLibrary]) so checkbox changes feel like
/// they actually decide something instead of racing a background
/// worker.
Future<void> showCacheChangesDialog(
  BuildContext context,
  WidgetRef ref,
  List<MediaChangeBundle> bundles,
) async {
  if (bundles.isEmpty) return;

  // Pre-selection rule per kind. Stored as a three-valued map because
  // unchecking an "added" entry means "skip it this round", which is
  // distinct from the pre-1.4.1 behaviour where added was always
  // auto-generated no matter what.
  final selected = <({String bundleId, int changeIdx})>{};
  for (final b in bundles) {
    for (var i = 0; i < b.changes.length; i++) {
      final kind = b.changes[i].kind;
      final preselect = kind == MediaChangeKind.added ||
          kind == MediaChangeKind.modified;
      if (preselect) {
        selected.add((bundleId: b.mediaId, changeIdx: i));
      }
    }
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: AppTheme.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Änderungen erkannt',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
            content: SizedBox(
              width: 580,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Seit der letzten Aktualisierung hat sich in deinem '
                      'Medien-Ordner etwas geändert. Entscheide pro '
                      'Eintrag, was mit dem Vorschaubild-Cache passieren '
                      'soll:',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Inline icon legend — same icons the rows use,
                    // so the user doesn't have to map colour names
                    // to what they see.
                    const _LegendRow(
                      icon: Icons.add_circle_outline,
                      colour: Colors.greenAccent,
                      text: 'Neu: Datei ist dazugekommen. Häkchen = '
                          'Vorschaubilder jetzt erstellen.',
                    ),
                    const SizedBox(height: 4),
                    const _LegendRow(
                      icon: Icons.warning_amber_rounded,
                      colour: Colors.orangeAccent,
                      text: 'Geändert: Datei ist anders (Name oder '
                          'Größe) — alter Cache ist vermutlich veraltet. '
                          'Häkchen = neu erstellen.',
                    ),
                    const SizedBox(height: 4),
                    const _LegendRow(
                      icon: Icons.remove_circle_outline,
                      colour: Colors.redAccent,
                      text: 'Entfernt: Datei ist nicht mehr da. '
                          'Häkchen = Cache löschen. Ohne Häkchen bleibt '
                          'der Cache liegen.',
                    ),
                    const SizedBox(height: 8),
                    for (final bundle in bundles) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 6),
                        child: Text(
                          bundle.title,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      for (int i = 0; i < bundle.changes.length; i++)
                        _ChangeRow(
                          change: bundle.changes[i],
                          checked: selected.contains(
                              (bundleId: bundle.mediaId, changeIdx: i)),
                          onToggle: (v) {
                            setState(() {
                              final key = (
                                bundleId: bundle.mediaId,
                                changeIdx: i
                              );
                              if (v) {
                                selected.add(key);
                              } else {
                                selected.remove(key);
                              }
                            });
                          },
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  // "Abbrechen" — leave cache untouched AND skip
                  // thumbnail generation for this scan. User can
                  // inspect the folder manually and refresh later.
                  ref
                      .read(mediaLibraryProvider.notifier)
                      .skipChangeDecisions();
                  Navigator.pop(ctx);
                },
                child: const Text(
                  'Abbrechen',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
              ),
              TextButton(
                onPressed: () async {
                  // Split selections into delete vs. rebuild sets
                  // based on each change's kind. The notifier then
                  // clears caches and — only for the rebuild set —
                  // kicks off a scoped generation pass.
                  final toDelete = <String>{};
                  final toRebuild = <String>{};
                  for (final bundle in bundles) {
                    for (var i = 0; i < bundle.changes.length; i++) {
                      final key = (bundleId: bundle.mediaId, changeIdx: i);
                      if (!selected.contains(key)) continue;
                      final change = bundle.changes[i];
                      switch (change.kind) {
                        case MediaChangeKind.removed:
                          toDelete.addAll(change.affectedPaths);
                          break;
                        case MediaChangeKind.added:
                        case MediaChangeKind.modified:
                          toRebuild.addAll(change.affectedPaths);
                          break;
                      }
                    }
                  }
                  Navigator.pop(ctx);
                  await ref
                      .read(mediaLibraryProvider.notifier)
                      .applyChangeDecisions(
                        pathsToDelete: toDelete,
                        pathsToRebuild: toRebuild,
                      );
                },
                child: const Text(
                  'Aktionen durchführen',
                  style: TextStyle(color: AppTheme.accent),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _LegendRow extends StatelessWidget {
  final IconData icon;
  final Color colour;
  final String text;
  const _LegendRow({
    required this.icon,
    required this.colour,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: colour, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  final MediaChange change;
  final bool checked;
  final ValueChanged<bool> onToggle;

  const _ChangeRow({
    required this.change,
    required this.checked,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, colour) = switch (change.kind) {
      MediaChangeKind.added =>
        (Icons.add_circle_outline, Colors.greenAccent),
      MediaChangeKind.removed =>
        (Icons.remove_circle_outline, Colors.redAccent),
      MediaChangeKind.modified =>
        (Icons.warning_amber_rounded, Colors.orangeAccent),
    };
    final action = switch (change.kind) {
      MediaChangeKind.added => 'Vorschaubilder jetzt erstellen',
      MediaChangeKind.removed => 'Cache für diese Datei löschen',
      MediaChangeKind.modified => 'Vorschaubilder neu erstellen',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: colour, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  change.description,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                  ),
                ),
                Text(
                  action,
                  style: TextStyle(
                    color: AppTheme.textMuted.withValues(alpha: 0.85),
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.9,
            child: Checkbox(
              value: checked,
              onChanged: (v) => onToggle(v ?? false),
              activeColor: AppTheme.accent,
            ),
          ),
        ],
      ),
    );
  }
}
