import 'package:hive/hive.dart';

abstract interface class MemoryRecoveryJournal {
  Future<List<Map<String, dynamic>>> readAll();

  Future<void> write(String operationId, Map<String, dynamic> record);

  Future<void> remove(String operationId);
}

class HiveMemoryRecoveryJournal implements MemoryRecoveryJournal {
  HiveMemoryRecoveryJournal(this._box, this._namespace);

  final Box<dynamic> _box;
  final String _namespace;

  String _key(String operationId) => '$_namespace:$operationId';

  @override
  Future<List<Map<String, dynamic>>> readAll() async => _box.keys
      .whereType<String>()
      .where((key) => key.startsWith('$_namespace:'))
      .map((key) => Map<String, dynamic>.from(_box.get(key) as Map))
      .toList(growable: false);

  @override
  Future<void> write(String operationId, Map<String, dynamic> record) =>
      _box.put(_key(operationId), record);

  @override
  Future<void> remove(String operationId) => _box.delete(_key(operationId));
}

class InMemoryMemoryRecoveryJournal implements MemoryRecoveryJournal {
  final Map<String, Map<String, dynamic>> _records = {};

  @override
  Future<List<Map<String, dynamic>>> readAll() async => _records.values
      .map((record) => Map<String, dynamic>.from(record))
      .toList(growable: false);

  @override
  Future<void> write(String operationId, Map<String, dynamic> record) async {
    _records[operationId] = Map<String, dynamic>.from(record);
  }

  @override
  Future<void> remove(String operationId) async {
    _records.remove(operationId);
  }
}
