import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

class AppSettings {
  final String? mediaFolderPath;
  final String? exportFolderPath;
  final bool subtitlesEnabled;
  final bool thumbnailsEnabled;
  // Gates "power user" capture features: screenshot + clip buttons in
  // the player, their keyboard shortcuts (1/2/P), and the Export-Ordner
  // setting. Default OFF so a fresh install shows only the basic player
  // chrome — users who need capture explicitly opt in.
  final bool advancedToolsEnabled;
  /// When true, thumbnail folders for media that is no longer present in
  /// the scanned library are kept around forever (instead of being
  /// pruned on every scan). Useful for users who juggle files on/off an
  /// external drive and don't want to regenerate thumbnails each time.
  /// Default OFF — aligns with "cache reflects current library".
  final bool keepCacheForRemovedMedia;

  const AppSettings({
    this.mediaFolderPath,
    this.exportFolderPath,
    this.subtitlesEnabled = true,
    this.thumbnailsEnabled = true,
    this.advancedToolsEnabled = false,
    this.keepCacheForRemovedMedia = false,
  });

  AppSettings copyWith({
    String? mediaFolderPath,
    String? exportFolderPath,
    bool? subtitlesEnabled,
    bool? thumbnailsEnabled,
    bool? advancedToolsEnabled,
    bool? keepCacheForRemovedMedia,
  }) {
    return AppSettings(
      mediaFolderPath: mediaFolderPath ?? this.mediaFolderPath,
      exportFolderPath: exportFolderPath ?? this.exportFolderPath,
      subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
      thumbnailsEnabled: thumbnailsEnabled ?? this.thumbnailsEnabled,
      advancedToolsEnabled:
          advancedToolsEnabled ?? this.advancedToolsEnabled,
      keepCacheForRemovedMedia:
          keepCacheForRemovedMedia ?? this.keepCacheForRemovedMedia,
    );
  }
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  final Box _box;

  SettingsNotifier(this._box)
      : super(AppSettings(
          mediaFolderPath: _box.get('mediaFolderPath'),
          exportFolderPath: _box.get('exportFolderPath'),
          subtitlesEnabled: _box.get('subtitlesEnabled', defaultValue: true),
          thumbnailsEnabled:
              _box.get('thumbnailsEnabled', defaultValue: true),
          advancedToolsEnabled:
              _box.get('advancedToolsEnabled', defaultValue: false),
          keepCacheForRemovedMedia:
              _box.get('keepCacheForRemovedMedia', defaultValue: false),
        ));

  Future<void> setMediaFolderPath(String path) async {
    await _box.put('mediaFolderPath', path);
    state = state.copyWith(mediaFolderPath: path);
  }

  Future<void> setExportFolderPath(String path) async {
    await _box.put('exportFolderPath', path);
    state = state.copyWith(exportFolderPath: path);
  }

  Future<void> setSubtitlesEnabled(bool enabled) async {
    await _box.put('subtitlesEnabled', enabled);
    state = state.copyWith(subtitlesEnabled: enabled);
  }

  Future<void> setThumbnailsEnabled(bool enabled) async {
    await _box.put('thumbnailsEnabled', enabled);
    state = state.copyWith(thumbnailsEnabled: enabled);
  }

  Future<void> setAdvancedToolsEnabled(bool enabled) async {
    await _box.put('advancedToolsEnabled', enabled);
    state = state.copyWith(advancedToolsEnabled: enabled);
  }

  Future<void> setKeepCacheForRemovedMedia(bool enabled) async {
    await _box.put('keepCacheForRemovedMedia', enabled);
    state = state.copyWith(keepCacheForRemovedMedia: enabled);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  final box = Hive.box('settings');
  return SettingsNotifier(box);
});
