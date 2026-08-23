import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/models/domain/model_capabilities.dart';

void main() {
  group('ModelCapabilityResolver', () {
    test('known multimodal families advertise vision', () {
      for (final id in [
        'gpt-4o-mini',
        'claude-sonnet-4',
        'gemini-1.5-flash',
        'qwen2.5-vl-7b-instruct',
        'llama3.2-vision:11b',
      ]) {
        expect(ModelCapabilityResolver.resolve(id).vision, isTrue, reason: id);
      }
    });

    test('text-only families and unknown ids default to no vision', () {
      for (final id in [
        'gpt-3.5-turbo-instruct',
        'deepseek-coder-v2',
        'mistral-7b-instruct',
        'totally-unknown-model',
      ]) {
        expect(ModelCapabilityResolver.resolve(id).vision, isFalse, reason: id);
      }
    });

    test('tools stay enabled by default and disable for known exceptions', () {
      expect(ModelCapabilityResolver.resolve('gpt-4o').tools, isTrue);
      expect(ModelCapabilityResolver.resolve('llama3.1-8b').tools, isTrue);
      expect(
        ModelCapabilityResolver.resolve('model-q4_K_M-gguf').tools,
        isFalse,
      );
      expect(
        ModelCapabilityResolver.resolve('text-embedding-3-small').tools,
        isFalse,
      );
    });

    test('resolution is case-insensitive', () {
      expect(ModelCapabilityResolver.resolve('GPT-4O-2026').vision, isTrue);
    });
  });

  group('filterAttachmentsForModel', () {
    const image = ChatAttachment(
      name: 'shot.png',
      mimeType: 'image/png',
      dataBase64: '',
    );
    const document = ChatAttachment(
      name: 'notes.md',
      mimeType: 'text/markdown',
      dataBase64: '',
    );
    const binary = ChatAttachment(
      name: 'blob.bin',
      mimeType: 'application/octet-stream',
      dataBase64: '',
    );

    test('vision-capable models keep everything', () {
      final filtered = filterAttachmentsForModel([
        image,
        document,
        binary,
      ], visionSupported: true);

      expect(filtered, hasLength(3));
    });

    test('without vision only non-image attachments survive', () {
      final filtered = filterAttachmentsForModel([
        image,
        document,
      ], visionSupported: false);

      expect(filtered, [document]);
    });
  });
}
