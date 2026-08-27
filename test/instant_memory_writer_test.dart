import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/memory/application/instant_memory_writer.dart';
import 'package:mobilka/features/memory/application/memory_mutation_coordinator.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'support/memory_delete_mixins.dart';

void main() {
  late _Boundary boundary;
  late InstantMemoryWriter writer;

  setUp(() {
    boundary = _Boundary({'memory.md': 'old\n'});
    writer = InstantMemoryWriter(MemoryMutationCoordinator(boundary));
  });

  test('replaces an existing memory notebook', () async {
    await writer.write('new\n');
    expect(boundary.files['memory.md'], startsWith('new\n'));
  });

  test('accepts guarded UTF-8 content below soft limit', () async {
    await writer.write('а' * 1000);
    expect(boundary.files['memory.md'], contains('а'));
  });

  test(
    'rejects content above soft limit without truncating or writing',
    () async {
      final before = boundary.files['memory.md'];
      await expectLater(
        writer.write('a' * (InstantMemoryWriter.softUtf8ByteLimit + 1)),
        throwsA(isA<StateError>()),
      );
      expect(boundary.files['memory.md'], before);
    },
  );
}

class _Boundary with MemoryBoundaryDelete implements MemoryFileBoundary {
  _Boundary(this.files);
  final Map<String, String> files;

  @override
  Future<String> read(String fileName) async => files[fileName]!;

  @override
  Future<void> write(String fileName, String content) async {
    files[fileName] = content;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(MemoryFileTransaction files) action,
  ) => action(_Transaction(this));
}

class _Transaction
    implements MemoryFileTransaction, MissingAwareMemoryFileTransaction {
  const _Transaction(this.boundary);
  final _Boundary boundary;

  @override
  Future<String> read(String fileName) => boundary.read(fileName);

  @override
  Future<String?> readIfExists(String fileName) async =>
      boundary.files[fileName];

  @override
  Future<void> write(String fileName, String content) =>
      boundary.write(fileName, content);
}
