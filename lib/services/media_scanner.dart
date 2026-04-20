import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/media_item.dart';
import '../models/episode.dart';

class MediaScanner {
  static const _videoExtensions = {'.mp4', '.mkv', '.avi', '.iso'};
  static const _subtitleExtensions = {'.srt', '.sub', '.ass', '.ssa', '.vtt'};
  static const _coverNames = {'cover.jpg', 'cover.png', 'poster.jpg', 'poster.png', 'folder.jpg'};
  // Landscape hero images. Kept separate from covers because a movie
  // folder with only `banner.jpg` should NOT silently get that as its
  // portrait cover — the aspect ratio is wrong and the grid looks bad.
  static const _bannerNames = {
    'banner.jpg', 'banner.png',
    'fanart.jpg', 'fanart.png',
    'backdrop.jpg', 'backdrop.png',
    'landscape.jpg', 'landscape.png',
  };
  // Image specifically for the "Weiterschauen" (continue-watching) card.
  // Kept distinct from cover + banner so users can provide a different
  // crop / thumbnail than the hero / poster.
  static const _thumbnailNames = {
    'thumbnail.jpg', 'thumbnail.png',
    'thumb.jpg', 'thumb.png',
  };

  static final _episodePattern = RegExp(
    r'[Ss](\d{1,2})\s*[Ee](\d{1,3})'
    r'|(\d{1,2})[xX](\d{1,3})'
    r'|[Ee]pisode\s*(\d{1,3})',
    caseSensitive: false,
  );

  static final _seasonPattern = RegExp(
    r'[Ss]eason\s*(\d{1,2})'
    r'|[Ss]taffel\s*(\d{1,2})'
    r'|[Ss](\d{1,2})$'
    r'|Season\s*(\d{1,2})',
    caseSensitive: false,
  );

  Future<List<MediaItem>> scanDirectory(String rootPath) async {
    final rootDir = Directory(rootPath);
    if (!await rootDir.exists()) return [];

    final items = <MediaItem>[];
    final entities = await rootDir.list(followLinks: false).toList();

    for (final entity in entities) {
      // Per-entry try/catch so a single problem folder (e.g. a path longer
      // than MAX_PATH on an older Windows without long-path support, or a
      // permissions hiccup) doesn't abort the entire library scan.
      try {
        if (entity is Directory) {
          final item = await _scanMediaFolder(entity);
          if (item != null) items.add(item);
        } else if (entity is File && _isVideoFile(entity.path)) {
          items.add(_createStandaloneMovie(entity));
        }
      } catch (_) {
        // Skip this entry, keep scanning the rest.
      }
    }

    items.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return items;
  }

  Future<MediaItem?> _scanMediaFolder(Directory dir) async {
    final dirName = p.basename(dir.path);
    final entities = await dir.list(followLinks: false).toList();

    final subDirs = entities.whereType<Directory>().toList();
    final files = entities.whereType<File>().toList();
    final videoFiles = files.where((f) => _isVideoFile(f.path)).toList();

    final coverPath = _findCoverImage(dir.path, files);
    final bannerPath = _findBannerImage(dir.path, files);
    final thumbnailPath = _findThumbnailImage(dir.path, files);

    // Check if this is a series (has season subdirectories)
    final seasonDirs = subDirs.where((d) => _isSeasonFolder(d.path)).toList();

    if (seasonDirs.isNotEmpty) {
      return await _createSeries(
          dir, dirName, seasonDirs, coverPath, bannerPath, thumbnailPath);
    }

    // Check if directory has video files with episode patterns
    final hasEpisodes = videoFiles.any((f) => _episodePattern.hasMatch(p.basename(f.path)));

    if (hasEpisodes && videoFiles.length > 1) {
      // Single-season series (episodes directly in folder)
      final episodes = _parseEpisodes(videoFiles, 1, files);
      return MediaItem(
        id: dir.path,
        title: dirName,
        path: dir.path,
        type: MediaType.series,
        coverImagePath: coverPath,
        bannerImagePath: bannerPath,
        thumbnailImagePath: thumbnailPath,
        seasons: [
          Season(number: 1, path: dir.path, episodes: episodes),
        ],
      );
    }

    if (videoFiles.isNotEmpty) {
      // Movie (folder with single or few video files, no episode pattern)
      return MediaItem(
        id: dir.path,
        title: dirName,
        path: dir.path,
        type: MediaType.movie,
        coverImagePath: coverPath,
        bannerImagePath: bannerPath,
        thumbnailImagePath: thumbnailPath,
        movieFilePath: videoFiles.first.path,
      );
    }

    return null;
  }

  Future<MediaItem> _createSeries(
    Directory dir,
    String title,
    List<Directory> seasonDirs,
    String? coverPath,
    String? bannerPath,
    String? thumbnailPath,
  ) async {
    final seasons = <Season>[];

    for (final seasonDir in seasonDirs) {
      try {
        final seasonNum = _parseSeasonNumber(seasonDir.path);
        final seasonEntities =
            await seasonDir.list(followLinks: false).toList();
        final seasonFiles = seasonEntities.whereType<File>().toList();
        final videoFiles =
            seasonFiles.where((f) => _isVideoFile(f.path)).toList();

        if (videoFiles.isNotEmpty) {
          final episodes = _parseEpisodes(videoFiles, seasonNum, seasonFiles);
          seasons.add(Season(
            number: seasonNum,
            path: seasonDir.path,
            episodes: episodes,
          ));
        }
      } catch (_) {
        // Skip unreadable / too-long-path season folders instead of
        // failing the whole series.
      }
    }

    seasons.sort((a, b) => a.number.compareTo(b.number));

    return MediaItem(
      id: dir.path,
      title: title,
      path: dir.path,
      type: MediaType.series,
      coverImagePath: coverPath,
      bannerImagePath: bannerPath,
      thumbnailImagePath: thumbnailPath,
      seasons: seasons,
    );
  }

  List<Episode> _parseEpisodes(List<File> videoFiles, int seasonNum, List<File> allFiles) {
    final episodes = <Episode>[];

    for (final file in videoFiles) {
      final fileName = p.basenameWithoutExtension(file.path);
      final match = _episodePattern.firstMatch(fileName);

      int episodeNum;
      int parsedSeason = seasonNum;

      if (match != null) {
        if (match.group(1) != null) {
          parsedSeason = int.parse(match.group(1)!);
          episodeNum = int.parse(match.group(2)!);
        } else if (match.group(3) != null) {
          parsedSeason = int.parse(match.group(3)!);
          episodeNum = int.parse(match.group(4)!);
        } else {
          episodeNum = int.parse(match.group(5)!);
        }
      } else {
        episodeNum = episodes.length + 1;
      }

      // Clean up title
      String title = fileName;
      if (match != null) {
        title = fileName.substring(match.end).trim();
        if (title.startsWith('-') || title.startsWith('_')) {
          title = title.substring(1).trim();
        }
      }
      if (title.isEmpty) title = fileName;

      final subtitlePath = _findSubtitle(file.path, allFiles);

      episodes.add(Episode(
        id: file.path,
        title: title,
        filePath: file.path,
        seasonNumber: parsedSeason,
        episodeNumber: episodeNum,
        subtitlePath: subtitlePath,
      ));
    }

    episodes.sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    return episodes;
  }

  MediaItem _createStandaloneMovie(File file) {
    final title = p.basenameWithoutExtension(file.path);
    return MediaItem(
      id: file.path,
      title: title,
      path: p.dirname(file.path),
      type: MediaType.movie,
      movieFilePath: file.path,
    );
  }

  bool _isVideoFile(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return _videoExtensions.contains(ext);
  }

  bool _isSeasonFolder(String dirPath) {
    final name = p.basename(dirPath).toLowerCase();
    return _seasonPattern.hasMatch(name) ||
        name.startsWith('season') ||
        name.startsWith('staffel') ||
        RegExp(r'^s\d{1,2}$').hasMatch(name);
  }

  int _parseSeasonNumber(String dirPath) {
    final name = p.basename(dirPath);
    final match = _seasonPattern.firstMatch(name);
    if (match != null) {
      for (int i = 1; i <= match.groupCount; i++) {
        if (match.group(i) != null) {
          return int.parse(match.group(i)!);
        }
      }
    }
    // Try extracting any number
    final numMatch = RegExp(r'(\d+)').firstMatch(name);
    if (numMatch != null) return int.parse(numMatch.group(1)!);
    return 1;
  }

  String? _findCoverImage(String dirPath, List<File> files) {
    for (final file in files) {
      final name = p.basename(file.path).toLowerCase();
      if (_coverNames.contains(name)) {
        return file.path;
      }
    }
    // Also check for any jpg/png that might be a cover — but exclude
    // known banner / thumbnail names, otherwise a folder that only
    // ships `banner.jpg` would get the landscape banner as its portrait
    // cover (wrong aspect ratio, looks bad in the grid).
    for (final file in files) {
      final name = p.basename(file.path).toLowerCase();
      if (_bannerNames.contains(name)) continue;
      if (_thumbnailNames.contains(name)) continue;
      final ext = p.extension(file.path).toLowerCase();
      if (ext == '.jpg' || ext == '.png') {
        return file.path;
      }
    }
    return null;
  }

  String? _findBannerImage(String dirPath, List<File> files) {
    for (final file in files) {
      final name = p.basename(file.path).toLowerCase();
      if (_bannerNames.contains(name)) {
        return file.path;
      }
    }
    return null;
  }

  String? _findThumbnailImage(String dirPath, List<File> files) {
    for (final file in files) {
      final name = p.basename(file.path).toLowerCase();
      if (_thumbnailNames.contains(name)) {
        return file.path;
      }
    }
    return null;
  }

  String? _findSubtitle(String videoPath, List<File> allFiles) {
    final videoName = p.basenameWithoutExtension(videoPath);
    for (final file in allFiles) {
      final ext = p.extension(file.path).toLowerCase();
      if (_subtitleExtensions.contains(ext)) {
        final subName = p.basenameWithoutExtension(file.path);
        if (subName == videoName || subName.startsWith(videoName)) {
          return file.path;
        }
      }
    }
    return null;
  }
}
