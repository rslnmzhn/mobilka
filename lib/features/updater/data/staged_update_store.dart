import 'package:hive/hive.dart';

import '../domain/staged_update_metadata.dart';

abstract interface class StagedUpdateStore {
  Future<StagedUpdateMetadata?> load();
  Future<void> save(StagedUpdateMetadata metadata);
  Future<void> clear();
}

class HiveStagedUpdateStore implements StagedUpdateStore {
  HiveStagedUpdateStore(this._box);

  static const key = 'updater.staged.v1';
  final Box<dynamic> _box;

  @override
  Future<StagedUpdateMetadata?> load() async =>
      StagedUpdateMetadata.tryDecode(_box.get(key));

  @override
  Future<void> save(StagedUpdateMetadata metadata) async {
    await _box.put(key, metadata.toJson());
    await _box.flush();
  }

  @override
  Future<void> clear() async {
    await _box.delete(key);
    await _box.flush();
  }
}

class MemoryStagedUpdateStore implements StagedUpdateStore {
  StagedUpdateMetadata? value;

  @override
  Future<StagedUpdateMetadata?> load() async => value;

  @override
  Future<void> save(StagedUpdateMetadata metadata) async => value = metadata;

  @override
  Future<void> clear() async => value = null;
}
