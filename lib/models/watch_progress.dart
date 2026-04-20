import 'package:hive/hive.dart';

part 'watch_progress.g.dart';

@HiveType(typeId: 0)
class WatchProgress extends HiveObject {
  @HiveField(0)
  final String mediaId;

  @HiveField(1)
  final String filePath;

  @HiveField(2)
  final Duration position;

  @HiveField(3)
  final Duration totalDuration;

  @HiveField(4)
  final DateTime lastWatched;

  @HiveField(5)
  final String? mediaTitle;

  @HiveField(6)
  final String? episodeTitle;

  @HiveField(7)
  final String? coverImagePath;

  WatchProgress({
    required this.mediaId,
    required this.filePath,
    required this.position,
    required this.totalDuration,
    required this.lastWatched,
    this.mediaTitle,
    this.episodeTitle,
    this.coverImagePath,
  });

  double get progressPercent {
    if (totalDuration.inMilliseconds == 0) return 0;
    return position.inMilliseconds / totalDuration.inMilliseconds;
  }

  bool get isCompleted => progressPercent > 0.9;
  bool get hasStarted => position.inSeconds > 3;
}
