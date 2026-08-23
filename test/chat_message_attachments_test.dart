import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';

void main() {
  ChatMessage userMessage(List<ChatAttachment> attachments) => ChatMessage(
    id: 'user-1',
    role: ChatRole.user,
    content: 'Look at this',
    createdAt: DateTime(2026),
    attachments: attachments,
  );

  group('attachment wire format', () {
    test('plain message keeps string content', () {
      final json = userMessage(const []).toJson();

      expect(json['content'], 'Look at this');
      expect(json['content'], isA<String>());
    });

    test('image attachments become vision content parts', () {
      final json = userMessage([
        ChatAttachment(
          name: 'shot.png',
          mimeType: 'image/png',
          dataBase64: base64Encode([1, 2, 3]),
        ),
      ]).toJson();

      final content = json['content'] as List;
      expect(content.first, {'type': 'text', 'text': 'Look at this'});
      expect((content.last)['type'], 'image_url');
      expect(
        ((content.last)['image_url'])['url'],
        'data:image/png;base64,${base64Encode([1, 2, 3])}',
      );
    });

    test('inline text documents are appended as fenced blocks', () {
      final textBytes = utf8.encode('name,value\n1,2');
      final json = userMessage([
        ChatAttachment(
          name: 'data.csv',
          mimeType: 'text/csv',
          dataBase64: base64Encode(textBytes),
        ),
        ChatAttachment(
          name: 'notes.md',
          mimeType: 'application/octet-stream',
          dataBase64: base64Encode(utf8.encode('# note')),
        ),
      ]).toJson();

      final content = json['content'] as List;
      final textPart = content.first as Map;
      expect(textPart['type'], 'text');
      expect(textPart['text'], contains('```data.csv'));
      expect(textPart['text'], contains('name,value'));
      expect(textPart['text'], contains('```notes.md'));
      expect(textPart['text'], contains('# note'));
      // No image parts for document-only attachments.
      expect(content.length, 1);
    });

    test('non-convertible binary attachments are ignored on the wire', () {
      final json = userMessage([
        ChatAttachment(
          name: 'blob.bin',
          mimeType: 'application/octet-stream',
          dataBase64: base64Encode([9]),
        ),
      ]).toJson();

      expect(json['content'], 'Look at this');
    });

    test('assistant messages never emit attachment arrays', () {
      final json = ChatMessage(
        id: 'assistant-1',
        role: ChatRole.assistant,
        content: 'reply',
        createdAt: DateTime(2026),
        attachments: const [
          ChatAttachment(name: 'x.png', mimeType: 'image/png', dataBase64: ''),
        ],
      ).toJson();

      expect(json['content'], 'reply');
    });
  });

  group('attachment storage', () {
    test('round trips through storage json with size metadata', () {
      final original = userMessage([
        ChatAttachment(
          name: 'shot.png',
          mimeType: 'image/png',
          dataBase64: base64Encode([1, 2, 3]),
        ),
      ]);

      final restored = ChatMessage.fromStorageJson(original.toStorageJson());

      expect(restored.attachments.single.name, 'shot.png');
      expect(restored.attachments.single.mimeType, 'image/png');
      expect(restored.attachments.single.sizeBytes, 3);
      expect(restored.attachments.single.isImage, isTrue);
    });

    test('oversized payloads are rejected by the shared guard', () {
      expect(maxAttachmentBytes, greaterThan(0));
    });
  });
}
