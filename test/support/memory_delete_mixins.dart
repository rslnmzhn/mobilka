import 'package:mobilka/features/memory/data/memory_file_store.dart';

/// No-op deletion for in-memory test boundaries.
mixin MemoryBoundaryDelete implements MemoryFileBoundary {
  @override
  Future<void> delete(String fileName) async {}
}

/// No-op deletion for fake SAF access in tests.
mixin SafAccessDeleteMixin implements SafMemoryAccess {
  @override
  Future<void> delete(String documentUri) async {}
}
