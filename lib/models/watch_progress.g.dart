// GENERATED CODE - Manual Hive TypeAdapter

part of 'watch_progress.dart';

class WatchProgressAdapter extends TypeAdapter<WatchProgress> {
  @override
  final int typeId = 0;

  @override
  WatchProgress read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return WatchProgress(
      mediaId: fields[0] as String,
      filePath: fields[1] as String,
      position: Duration(milliseconds: fields[2] as int),
      totalDuration: Duration(milliseconds: fields[3] as int),
      lastWatched: DateTime.fromMillisecondsSinceEpoch(fields[4] as int),
      mediaTitle: fields[5] as String?,
      episodeTitle: fields[6] as String?,
      coverImagePath: fields[7] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, WatchProgress obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.mediaId)
      ..writeByte(1)
      ..write(obj.filePath)
      ..writeByte(2)
      ..write(obj.position.inMilliseconds)
      ..writeByte(3)
      ..write(obj.totalDuration.inMilliseconds)
      ..writeByte(4)
      ..write(obj.lastWatched.millisecondsSinceEpoch)
      ..writeByte(5)
      ..write(obj.mediaTitle)
      ..writeByte(6)
      ..write(obj.episodeTitle)
      ..writeByte(7)
      ..write(obj.coverImagePath);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WatchProgressAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
