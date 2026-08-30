import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/memory_repository.dart';
import 'persona_registry.dart';

/// The single readiness barrier for a configured memory location.
///
/// Riverpod retains exactly one future for the current location revision. All
/// consumers must await this barrier instead of starting recovery/migration in
/// the background.
final memoryLocationReadyProvider = FutureProvider<void>((ref) async {
  ref.watch(memoryLocationRevisionProvider);
  final repository = ref.watch(memoryRepositoryProvider);
  if (repository.savedLocation() == null) return;
  await ref.watch(personaRegistryProvider)?.ensureReady();
}, name: 'memory_location_ready');
