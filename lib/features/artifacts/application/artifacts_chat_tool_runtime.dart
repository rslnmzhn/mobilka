import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../chat/application/chat_tool_runtime.dart';
import '../../chat/domain/chat_message.dart';
import '../../chat/domain/chat_tool.dart';
import 'artifacts_controller.dart';
import 'artifact_policy.dart';

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
  );
});

/// Exposes `generate_docx` to the model: creates a Markdown artifact plus a
/// generated `.docx` sibling. Additive and sandboxed, so no confirmation step
/// is required — [ArtifactPolicy] quotas still apply.
class ArtifactsChatToolRuntime implements ChatToolRuntime {
  ArtifactsChatToolRuntime({
    required ArtifactsController Function() controller,
    required Iterable<String> Function() storedContents,
  }) : _controller = controller,
       _storedContents = storedContents;

  static const generateDocx = ChatToolDefinition(
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
  Future<String> executeTool(ChatToolCall call, Set<String> allowedTools) {
    if (!allowedTools.contains(generateDocx.name)) {
      throw ArtifactsToolPermissionException(
        'generate_docx is not allowed for this agent',
      );
    }
    return _execute(call);
  }

  Future<String> _execute(ChatToolCall call) async {
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

      final artifact = await controller.createDocxArtifact(
        title: title,
        markdown: markdown,
      );
      return jsonEncode({
        'ok': true,
        'artifact_id': artifact.id,
        'file_name': '${artifact.id}.docx',
      });
    } on ArtifactPolicyException catch (error) {
      return jsonEncode({'ok': false, 'error': error.messageKey});
    } on FormatException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    }
  }
}
