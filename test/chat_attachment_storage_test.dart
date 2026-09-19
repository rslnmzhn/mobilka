import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/chat_attachment_storage.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/chat/domain/conversation.dart';
import 'package:mobilka/features/chat/application/chat_stream_request.dart';
import 'package:mobilka/features/chat/application/send_again_service.dart';
import 'package:mobilka/features/memory/data/memory_file_store.dart';

void main() {
  ChatAttachment attachment(String name) => ChatAttachment(
    name: name,
    mimeType: 'image/png',
    dataBase64: base64Encode([1, 2, 3]),
  );

  test(
    'copies originals to allowed paths without replacing transcript or names',
    () async {
      final root = await Directory.systemTemp.createTemp('attachments-');
      addTearDown(() => root.delete(recursive: true));
      final store = PathMemoryFileStore(root.path);
      await store.writeSubPath('sessions/key/session.md', 'transcript');
      final saved = await storeChatAttachments(
        attachments: [
          attachment('session.md'),
          attachment('../photo.png'),
          attachment('../photo.png'),
          attachment('фото.png'),
        ],
        sessionKey: 'key',
        write: (path, bytes, mime) =>
            store.writeSubPathBytes(path, bytes, mimeType: mime),
      );
      expect(saved.map((a) => a.workspacePath).toSet(), hasLength(4));
      for (final file in saved) {
        final path = 'sessions/key/${file.workspacePath}';
        expect(MemoryFileValidation.subPath(path), isNotNull);
        expect(await File('${root.path}/$path').readAsBytes(), [1, 2, 3]);
        expect(file.sourceSha256, sha256.convert([1, 2, 3]).toString());
        expect(
          await store.writeSubPathBytes(path, Uint8List.fromList([9])),
          isFalse,
        );
        expect(await File('${root.path}/$path').readAsBytes(), [1, 2, 3]);
      }
      expect(await store.readSubPath('sessions/key/session.md'), 'transcript');
    },
  );

  test(
    'false and thrown writes abort instead of reporting saved metadata',
    () async {
      await expectLater(
        storeChatAttachments(
          attachments: [attachment('a.png')],
          sessionKey: 'key',
          write: (_, _, _) async => false,
        ),
        throwsStateError,
      );
      await expectLater(
        storeChatAttachments(
          attachments: [attachment('a.png')],
          sessionKey: 'key',
          write: (_, _, _) async => throw const FileSystemException('denied'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('nonvision requests and retries keep file metadata but omit images', () {
    final file = attachment('a.png').withWorkspace('artifacts/a.png', 'hash');
    final now = DateTime(2026);
    final conversation = Conversation(
      id: 'c',
      title: 'c',
      modelId: 'deepseek-chat',
      createdAt: now,
      updatedAt: now,
      pendingRequestMessageId: 'u',
      messages: [
        ChatMessage(
          id: 'u',
          role: ChatRole.user,
          content: '',
          createdAt: now,
          attachments: [file],
        ),
      ],
    );
    final request = buildChatStreamRequest(
      conversation,
      'u',
      'a',
      selectedAgentId: null,
      allowedTools: {},
    );
    expect(
      request.history.single.toJson()['content'],
      contains('artifacts/a.png'),
    );
    expect(
      request.history.single.toJson()['content'],
      isNot(contains('image_url')),
    );
    expect(
      conversation.messages.single.attachments.single.includeImageData,
      isTrue,
    );
    final retried = prepareInterruptedRetry(
      conversation,
      now,
      selectedAgentId: null,
      allowedTools: {},
    )!;
    expect(
      retried.request.history.single.toJson()['content'],
      contains('source_sha256'),
    );
    final again = const SendAgainService().prepare(
      messageId: 'u',
      now: now,
      onInvalid: () => fail('attachment-only message is valid'),
      onAttachmentsFiltered: () {},
    );
    final copied = again.mutation(conversation)!;
    expect(
      copied.messages
          .where((m) => m.role == ChatRole.user)
          .last
          .attachments
          .single
          .workspacePath,
      'artifacts/a.png',
    );
  });

  test(
    'metadata survives storage and nonvision wire with no invented prompt',
    () {
      final original = attachment(
        'фото.png',
      ).withWorkspace('artifacts/file.png', 'hash');
      final restored = ChatAttachment.fromStorageJson(original.toStorageJson());
      final message = ChatMessage(
        id: 'u',
        role: ChatRole.user,
        content: '',
        createdAt: DateTime(2026),
        attachments: [restored.withoutImageData()],
      );
      expect(message.content, isEmpty);
      final wire = message.toJson()['content'] as String;
      expect(jsonDecode(wire), {
        'attachments': [
          {
            'name': 'фото.png',
            'path': 'artifacts/file.png',
            'source_sha256': 'hash',
          },
        ],
      });
      expect(restored.dataBase64, original.dataBase64);
    },
  );
}
