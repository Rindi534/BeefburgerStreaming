class Episode {
  final String id;
  final String title;
  final String filePath;
  final int seasonNumber;
  final int episodeNumber;
  final String? subtitlePath;

  const Episode({
    required this.id,
    required this.title,
    required this.filePath,
    required this.seasonNumber,
    required this.episodeNumber,
    this.subtitlePath,
  });

  String get displayName => 'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';

  String get fullDisplayName => '$displayName - $title';
}
