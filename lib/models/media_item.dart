import 'episode.dart';

enum MediaType { movie, series }

class MediaItem {
  final String id;
  final String title;
  final String path;
  final MediaType type;
  /// Portrait image shown in the grid on the home screen.
  /// File names: cover.{jpg,png}, poster.{jpg,png}, folder.jpg.
  final String? coverImagePath;
  /// Landscape hero image shown at the top of the series detail screen
  /// (above the episode list) and as a fallback for the continue-watching
  /// row if no thumbnail is provided.
  /// File names: banner.{jpg,png}, fanart.{jpg,png}, backdrop.{jpg,png},
  /// landscape.{jpg,png}.
  final String? bannerImagePath;
  /// Image specifically for the "Weiterschauen" row card.
  /// File names: thumbnail.{jpg,png}, thumb.{jpg,png}.
  /// Fallback chain inside the UI is: thumbnail → banner → cover.
  final String? thumbnailImagePath;
  final List<Season> seasons;
  final String? movieFilePath;

  const MediaItem({
    required this.id,
    required this.title,
    required this.path,
    required this.type,
    this.coverImagePath,
    this.bannerImagePath,
    this.thumbnailImagePath,
    this.seasons = const [],
    this.movieFilePath,
  });

  List<Episode> get allEpisodes =>
      seasons.expand((s) => s.episodes).toList();

  int get totalEpisodes => allEpisodes.length;
}

class Season {
  final int number;
  final String path;
  final List<Episode> episodes;

  const Season({
    required this.number,
    required this.path,
    required this.episodes,
  });

  String get displayName => 'Staffel $number';
}
