part of 'saf_memory_file_store.dart';

class _SafMemoryFileTransaction
    implements
        MemoryFileTransaction,
        MissingAwareMemoryFileTransaction,
        DeletingMemoryFileTransaction,
        PersonaTreeTransaction {
  _SafMemoryFileTransaction(this.store, this.documents);
  final SafMemoryFileStore store;
  final List<SafMemoryDocument> documents;
  SafMemoryAccess get access => store._access;

  List<SafMemoryDocument> _matches(String name) {
    MemoryFileValidation.validateFileName(name);
    return documents.where((item) => item.name == name).toList();
  }

  @override
  Future<String> read(String name) async {
    final value = await readIfExists(name);
    if (value == null) throw StateError('Memory file not found: $name');
    return value;
  }

  @override
  Future<String?> readIfExists(String name) async {
    if (MemoryFileValidation.isPersonaPath(name)) {
      final parts = name.split('/');
      final parent = await store._findParent(parts);
      if (parent == null) return null;
      final child = await store._resolveExactChild(
        parent,
        parts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      return child == null
          ? null
          : MemoryFileCodec.decode(await access.read(child.uri));
    }
    final matches = _matches(name);
    if (matches.isEmpty) return null;
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file is ambiguous: $name');
    }
    return MemoryFileCodec.decode(await access.read(matches.single.uri));
  }

  @override
  Future<void> write(String name, String content) async {
    MemoryFileValidation.validateFileName(name);
    if (!MemoryFileValidation.isPersonaPath(name)) {
      await access.write(
        store.directoryUri,
        name,
        MemoryFileCodec.encode(content),
        overwrite: true,
      );
      return;
    }
    final leaf = name.split('/').last;
    final parent = await store._resolveOrCreateDirectories(const ['personas']);
    final existing = await store._resolveExactChild(
      parent,
      leaf,
      expectedDirectory: false,
      allowMissing: true,
    );
    await access.write(
      parent,
      leaf,
      MemoryFileCodec.encode(content),
      overwrite: existing != null,
    );
    final verified = await store._resolveExactChild(
      parent,
      leaf,
      expectedDirectory: false,
      allowMissing: false,
    );
    if (verified == null ||
        MemoryFileCodec.decode(await access.read(verified.uri)) != content) {
      throw StateError('SAF persona readback could not be verified');
    }
  }

  @override
  Future<void> delete(String name) async {
    if (MemoryFileValidation.isPersonaPath(name)) {
      final parts = name.split('/');
      final parent = await store._findParent(parts);
      if (parent == null) return;
      final child = await store._resolveExactChild(
        parent,
        parts.last,
        expectedDirectory: false,
        allowMissing: true,
      );
      if (child != null) await access.delete(child.uri);
      if (await store._resolveExactChild(
            parent,
            parts.last,
            expectedDirectory: false,
            allowMissing: true,
          ) !=
          null) {
        throw StateError('SAF persona deletion is indeterminate');
      }
      return;
    }
    final matches = _matches(name);
    if (matches.isEmpty) return;
    if (matches.length != 1 || matches.single.isDirectory) {
      throw StateError('Memory file is ambiguous: $name');
    }
    await access.delete(matches.single.uri);
    documents.remove(matches.single);
  }

  @override
  Future<List<String>> listPersonaFiles() async {
    final parent = await store._findParent(const ['personas', 'entry.md']);
    if (parent == null) return const [];
    final children = await access.list(parent);
    final names = children
        .where((item) => !item.isDirectory && item.name.endsWith('.md'))
        .map((item) => item.name)
        .where(
          (name) => MemoryFileValidation.isPersonaSlug(
            name.substring(0, name.length - 3),
          ),
        )
        .toList();
    for (final name in names) {
      await store._resolveExactChild(
        parent,
        name,
        expectedDirectory: false,
        allowMissing: false,
        children: children,
      );
    }
    names.sort();
    return names;
  }
}
