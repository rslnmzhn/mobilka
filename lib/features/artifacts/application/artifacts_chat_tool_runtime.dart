import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import '../../memory/application/workspace_paths.dart';
import '../../memory/data/memory_repository.dart';
import 'artifacts_controller.dart';
import 'artifact_policy.dart';
import '../domain/artifact_link.dart';

class ArtifactsToolPermissionException extends StateError {
  ArtifactsToolPermissionException(super.message);
}

final artifactsChatToolRuntimeProvider = Provider<ArtifactsChatToolRuntime>((
  ref,
) {
  return ArtifactsChatToolRuntime(
    controller: () => ref.read(artifactsControllerProvider.notifier),
    storedContents: () =>
        ref.read(artifactsControllerProvider).map((item) => item.content),
    workspace: WorkspaceStore(repository: ref.read(memoryRepositoryProvider)),
  );
});

/// Exposes `generate_docx` to the model: creates a Markdown artifact plus a
/// generated `.docx` sibling. Additive and sandboxed, so no confirmation step
/// is required — [ArtifactPolicy] quotas still apply.
class ArtifactsChatToolRuntime implements ChatToolRuntime {
  ArtifactsChatToolRuntime({
    required ArtifactsController Function() controller,
    required Iterable<String> Function() storedContents,
    required WorkspaceStore workspace,
  }) : _controller = controller,
       _storedContents = storedContents,
       _workspace = workspace;

  static const generateDocx = ChatToolDefinition(
    effect: ChatToolEffect.mutating,
    name: 'generate_docx',
    description:
        'Create a downloadable .docx document artifact from Markdown. '
        'Supports headings (#..###), bullet/ordered lists, fenced code '
        'blocks, blockquotes, horizontal rules, **bold**, *italic*, `code`.',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {
          'type': 'string',
          'description': 'Document title shown to the user.',
        },
        'markdown': {
          'type': 'string',
          'description': 'Complete document body in Markdown.',
        },
      },
      'required': ['title', 'markdown'],
      'additionalProperties': false,
    },
  );

  final ArtifactsController Function() _controller;
  final Iterable<String> Function() _storedContents;
  final WorkspaceStore _workspace;

  @override
  Future<List<ChatToolDefinition>> availableTools(
    Set<String> allowedTools,
  ) async {
    if (allowedTools.contains(generateDocx.name)) {
      return const [generateDocx];
    }
    return const [];
  }

  @override
  Future<String> executeTool(
    ChatToolCall call,
    Set<String> allowedTools, {
    ChatToolExecutionContext? context,
  }) {
    if (!allowedTools.contains(generateDocx.name)) {
      throw ArtifactsToolPermissionException(
        'generate_docx is not allowed for this agent',
      );
    }
    return _execute(call, context);
  }

  Future<String> _execute(
    ChatToolCall call,
    ChatToolExecutionContext? context,
  ) async {
    try {
      final arguments = jsonDecode(call.arguments);
      if (arguments is! Map) {
        throw const FormatException(
          'generate_docx arguments must be an object',
        );
      }
      final title = arguments['title']?.toString() ?? '';
      final markdown = arguments['markdown']?.toString() ?? '';
      ArtifactPolicy.validateDocument(title, markdown);

      final controller = _controller();
      final stored = _storedContents();
      ArtifactPolicy.validateQuotas(
        documentCount: stored.length + 1,
        totalBytes:
            stored.fold<int>(
              0,
              (sum, content) => sum + ArtifactPolicy.bytesOf(content),
            ) +
            ArtifactPolicy.bytesOf(markdown),
      );

      final generated = await controller.createDocxArtifact(
        title: title,
        markdown: markdown,
        conversationId: context?.conversationId,
        sessionKey: context?.sessionKey,
      );
      final mirror = await _mirror(generated, markdown, context);
      final link = ArtifactLink(
        artifactId: generated.artifact.id,
        representation: ArtifactRepresentation.docx,
      );
      return jsonEncode({
        'ok': true,
        'artifact_id': generated.artifact.id,
        'file_name': '${generated.artifact.id}.docx',
        'artifact_uri': link.toString(),
        'artifact_markdown': '[${generated.artifact.title}]($link)',
        'workspace_saved': mirror.saved,
        'workspace_status': ?mirror.status,
      });
    } on ArtifactPolicyException catch (error) {
      return jsonEncode({'ok': false, 'error': error.messageKey});
    } on FormatException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    }
  }

  Future<({bool saved, String? status})> _mirror(
    CreatedDocxArtifact generated,
    String markdown,
    ChatToolExecutionContext? context,
  ) async {
    final sessionKey = context?.sessionKey;
    final binding = context?.workspaceBinding;
    if (sessionKey == null || sessionKey.isEmpty || binding == null) {
      return (
        saved: false,
        status: 'Workspace mirror skipped: session context unavailable.',
      );
    }
    try {
      final result = await _workspace.writeArtifactPair(
        binding: binding,
        sessionKey: sessionKey,
        artifactId: generated.artifact.id,
        markdown: markdown,
        docxBytes: generated.docxBytes,
      );
      if (result.complete) return (saved: true, status: null);
      final status = result.hasCollision
          ? 'Workspace mirror collision: existing artifact siblings were preserved.'
          : result.hasIndeterminate
          ? 'Workspace mirror outcome is indeterminate; app artifact remains available.'
          : result.firstWritten
          ? 'Workspace mirror incomplete: Markdown saved but DOCX was not saved.'
          : 'Workspace mirror was not saved; app artifact remains available.';
      return (saved: false, status: status);
    } on Object {
      return (
        saved: false,
        status: 'Workspace mirror unavailable; app artifact remains available.',
      );
    }
  }
}
