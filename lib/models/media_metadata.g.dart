// GENERATED CODE - Manual Hive TypeAdapter

part of 'media_metadata.dart';

class MediaMetadataAdapter extends TypeAdapter<MediaMetadata> {
  @override
  final int typeId = 1;

  @override
  MediaMetadata read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return MediaMetadata(
      mediaId: fields[0] as String,
      title: fields[1] as String,
      typeIndex: fields[2] as int,
      keepCache: fields[3] as bool,
      firstSeen: DateTime.fromMillisecondsSinceEpoch(fields[4] as int),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(fields[5] as int),
      snapshotJson: fields[6] as String,
    );
  }

  @override
  void write(BinaryWriter writer, MediaMetadata obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.mediaId)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.typeIndex)
      ..writeByte(3)
      ..write(obj.keepCache)
      ..writeByte(4)
      ..write(obj.firstSeen.millisecondsSinceEpoch)
      ..writeByte(5)
      ..write(obj.lastSeen.millisecondsSinceEpoch)
      ..writeByte(6)
      ..write(obj.snapshotJson);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaMetadataAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
