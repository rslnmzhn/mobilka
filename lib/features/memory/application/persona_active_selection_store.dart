import 'dart:async';

import 'package:hive/hive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_boxes.dart';
import '../data/memory_repository.dart';
import 'memory_mutation_coordinator.dart';

abstract interface class PersonaActiveSelectionStore {
  String? read();
  Future<void> write(String? id);
  String? readLegacyName();
  Future<void> clearLegacyName();
}

class HivePersonaActiveSelectionStore implements PersonaActiveSelectionStore {
  HivePersonaActiveSelectionStore(this._box, this._locationId);

  final Box<dynamic> _box;
  final String _locationId;
  String get _key => 'activePersona:$_locationId';

  @override
  String? read() => _box.get(_key) as String?;

  @override
  Future<void> write(String? id) => _box.put(_key, id);

  @override
  String? readLegacyName() => _box.get('activePersona') as String?;

  @override
  Future<void> clearLegacyName() => _box.delete('activePersona');
}

class CallbackPersonaActiveSelectionStore
    implements PersonaActiveSelectionStore {
  CallbackPersonaActiveSelectionStore(this.readId, this.writeId);
  final String? Function() readId;
  final FutureOr<void> Function(String? id) writeId;

  @override
  String? read() => readId();
  @override
  Future<void> write(String? id) => Future<void>.sync(() => writeId(id));
  @override
  String? readLegacyName() => null;
  @override
  Future<void> clearLegacyName() async {}
}

class ActivePersonaController extends Notifier<String?> {
  late PersonaActiveSelectionStore _store;
  @override
  String? build() {
    ref.watch(memoryLocationRevisionProvider);
    final location = ref.watch(memoryRepositoryProvider).savedLocation();
    _store = location == null
        ? CallbackPersonaActiveSelectionStore(() => null, (_) {})
        : HivePersonaActiveSelectionStore(
            preferencesBox,
            checksum(location.value),
          );
    return _store.read();
  }

  Future<void> set(String? id) async {
    await _store.write(id);
    state = id;
  }

  String? readLegacyName() => _store.readLegacyName();
  Future<void> clearLegacyName() => _store.clearLegacyName();
}

final activePersonaControllerProvider =
    NotifierProvider<ActivePersonaController, String?>(
      ActivePersonaController.new,
      name: 'active_persona_controller',
    );

class ReactivePersonaActiveSelectionStore
    implements PersonaActiveSelectionStore {
  ReactivePersonaActiveSelectionStore(this.ref);
  final Ref ref;
  ActivePersonaController get _controller =>
      ref.read(activePersonaControllerProvider.notifier);
  @override
  String? read() => ref.read(activePersonaControllerProvider);
  @override
  Future<void> write(String? id) => _controller.set(id);
  @override
  String? readLegacyName() => _controller.readLegacyName();
  @override
  Future<void> clearLegacyName() => _controller.clearLegacyName();
}
