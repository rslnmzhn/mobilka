import 'package:hive/hive.dart';
import 'package:synchronized/synchronized.dart';

class MemoryProposalBinding {
  const MemoryProposalBinding({
    required this.fileName,
    required this.contentHash,
    required this.diffHash,
    required this.version,
    required this.locationId,
    required this.createdAt,
  });

  final String fileName;
  final String contentHash;
  final String diffHash;
  final String version;
  final String locationId;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
    'fileName': fileName,
    'contentHash': contentHash,
    'diffHash': diffHash,
    'version': version,
    'locationId': locationId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': 'pending',
  };
}

class MemoryProposalApplyResult {
  const MemoryProposalApplyResult({
    required this.previousVersion,
    required this.version,
  });

  final String previousVersion;
  final String version;
}

sealed class MemoryProposalClaim {
  const MemoryProposalClaim();
}

class MemoryProposalClaimed extends MemoryProposalClaim {
  const MemoryProposalClaimed(this.binding);
  final MemoryProposalBinding binding;
}

class MemoryProposalAlreadyApplied extends MemoryProposalClaim {
  const MemoryProposalAlreadyApplied(this.binding, this.result);
  final MemoryProposalBinding binding;
  final MemoryProposalApplyResult result;
}

abstract interface class MemoryUpdateProposalAuthority {
  Future<void> issue(String token, MemoryProposalBinding binding);
  Future<MemoryProposalClaim> claim(String token);
  Future<void> complete(String token, MemoryProposalApplyResult result);
  Future<void> release(String token);
  Future<void> recoverApplying();
  Future<void> revoke(String token);
}

class HiveMemoryUpdateProposalAuthority
    implements MemoryUpdateProposalAuthority {
  HiveMemoryUpdateProposalAuthority(this._box);

  final Box<dynamic> _box;
  static final Expando<Lock> _locks = Expando();
  Lock get _lock => _locks[_box] ??= Lock();

  @override
  Future<void> issue(String token, MemoryProposalBinding binding) =>
      _lock.synchronized(() => _box.put(token, binding.toJson()));

  @override
  Future<MemoryProposalClaim> claim(String token) =>
      _lock.synchronized(() async {
        final record = _read(token);
        if (record == null) {
          throw const UnknownMemoryProposalAuthorityException();
        }
        if (record['status'] == 'applied') {
          return MemoryProposalAlreadyApplied(
            _bindingFrom(record),
            MemoryProposalApplyResult(
              previousVersion: record['previousVersion'].toString(),
              version: record['resultVersion'].toString(),
            ),
          );
        }
        if (record['status'] != 'pending') {
          throw const UnknownMemoryProposalAuthorityException();
        }
        await _box.put(token, {...record, 'status': 'applying'});
        return MemoryProposalClaimed(_bindingFrom(record));
      });

  @override
  Future<void> complete(String token, MemoryProposalApplyResult result) =>
      _lock.synchronized(() async {
        final record = _read(token);
        if (record == null || record['status'] != 'applying') {
          throw const UnknownMemoryProposalAuthorityException();
        }
        await _box.put(token, {
          ...record,
          'status': 'applied',
          'previousVersion': result.previousVersion,
          'resultVersion': result.version,
        });
      });

  @override
  Future<void> release(String token) => _lock.synchronized(() async {
    final record = _read(token);
    if (record != null && record['status'] == 'applying') {
      await _box.put(token, {...record, 'status': 'pending'});
    }
  });

  @override
  Future<void> recoverApplying() => _lock.synchronized(() async {
    for (final key in _box.keys) {
      final token = key.toString();
      final record = _read(token);
      if (record != null && record['status'] == 'applying') {
        await _box.put(token, {...record, 'status': 'pending'});
      }
    }
  });

  @override
  Future<void> revoke(String token) =>
      _lock.synchronized(() => _box.delete(token));

  Map<dynamic, dynamic>? _read(String token) {
    final value = _box.get(token);
    return value is Map ? value : null;
  }
}

class InMemoryMemoryUpdateProposalAuthority
    implements MemoryUpdateProposalAuthority {
  final Map<String, Map<String, Object>> _records = {};
  final Lock _lock = Lock();

  @override
  Future<void> issue(String token, MemoryProposalBinding binding) =>
      _lock.synchronized(() async => _records[token] = binding.toJson());

  @override
  Future<MemoryProposalClaim> claim(String token) =>
      _lock.synchronized(() async {
        final record = _records[token];
        if (record == null) {
          throw const UnknownMemoryProposalAuthorityException();
        }
        if (record['status'] == 'applied') {
          return MemoryProposalAlreadyApplied(
            _bindingFrom(record),
            MemoryProposalApplyResult(
              previousVersion: record['previousVersion'].toString(),
              version: record['resultVersion'].toString(),
            ),
          );
        }
        if (record['status'] != 'pending') {
          throw const UnknownMemoryProposalAuthorityException();
        }
        _records[token] = {...record, 'status': 'applying'};
        return MemoryProposalClaimed(_bindingFrom(record));
      });

  @override
  Future<void> complete(String token, MemoryProposalApplyResult result) =>
      _lock.synchronized(() async {
        final record = _records[token];
        if (record == null || record['status'] != 'applying') {
          throw const UnknownMemoryProposalAuthorityException();
        }
        _records[token] = {
          ...record,
          'status': 'applied',
          'previousVersion': result.previousVersion,
          'resultVersion': result.version,
        };
      });

  @override
  Future<void> release(String token) => _lock.synchronized(() async {
    final record = _records[token];
    if (record != null && record['status'] == 'applying') {
      _records[token] = {...record, 'status': 'pending'};
    }
  });

  @override
  Future<void> recoverApplying() => _lock.synchronized(() async {
    for (final entry in _records.entries.toList()) {
      if (entry.value['status'] == 'applying') {
        _records[entry.key] = {...entry.value, 'status': 'pending'};
      }
    }
  });

  @override
  Future<void> revoke(String token) =>
      _lock.synchronized(() async => _records.remove(token));
}

MemoryProposalBinding _bindingFrom(Map<dynamic, dynamic> record) =>
    MemoryProposalBinding(
      fileName: record['fileName'].toString(),
      contentHash: record['contentHash'].toString(),
      diffHash: record['diffHash'].toString(),
      version: record['version'].toString(),
      locationId: record['locationId'].toString(),
      createdAt: DateTime.parse(record['createdAt'].toString()),
    );

class UnknownMemoryProposalAuthorityException implements Exception {
  const UnknownMemoryProposalAuthorityException();
}
