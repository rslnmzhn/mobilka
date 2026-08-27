import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/memory/application/skills_chat_tools.dart';
import 'package:mobilka/features/memory/application/workspace_paths.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';
import 'package:mobilka/features/memory/data/memory_repository.dart';
import 'package:saf/saf.dart';

void main() {
  test('skills runtime writes, reads, and lists path-backed skills', () async {
    final root = await Directory.systemTemp.createTemp('skills-runtime-');
    addTearDown(() => root.delete(recursive: true));
    final location = MemoryLocation(value: root.path, isContentUri: false);
    final tools = SkillsChatTools(
      workspace: WorkspaceStore(
        repository: _SkillsRepository(location, PathMemoryFileStore(root.path)),
      ),
    );
    const allowed = {'write_skill', 'read_skill', 'list_skills'};

    final written =
        jsonDecode(
              await tools.executeTool(
                const ChatToolCall(
                  id: 'write',
                  name: 'write_skill',
                  arguments: '{"name":"runtime-check","content":"# Reusable"}',
                ),
                allowed,
              ),
            )
            as Map<String, dynamic>;
    final read =
        jsonDecode(
              await tools.executeTool(
                const ChatToolCall(
                  id: 'read',
                  name: 'read_skill',
                  arguments: '{"name":"runtime-check"}',
                ),
                allowed,
              ),
            )
            as Map<String, dynamic>;
    final listed =
        jsonDecode(
              await tools.executeTool(
                const ChatToolCall(
                  id: 'list',
                  name: 'list_skills',
                  arguments: '{}',
                ),
                allowed,
              ),
            )
            as Map<String, dynamic>;

    expect(written['ok'], isTrue);
    expect(read, containsPair('content', '# Reusable'));
    expect(listed['skills'], ['runtime-check.md']);
  });
}

class _SkillsRepository extends MemoryRepository {
  _SkillsRepository(this.location, this.boundary) : super(Saf());

  final MemoryLocation location;
  final MemoryFileBoundary boundary;

  @override
  MemoryLocation? savedLocation() => location;

  @override
  MemoryFileBoundary boundaryFor(MemoryLocation location) => boundary;

  @override
  Future<void> validateSavedLocationAccess(MemoryLocation location) async {}
}
