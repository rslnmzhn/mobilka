import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/tool_instruction_synchronizer.dart';

void main() {
  const synchronizer = ToolInstructionSynchronizer();

  const samplePrompt = '''
## Role & System Instructions
Ты — ассистент mobilka.

## Документы и OCR
- `extract_document`: безопасное локальное извлечение структурированного текста из таблиц.
- `ocr_document`: офлайн-распознавание текста на изображениях (PNG, JPEG).
- Если пользователю нужно распознать текст с изображения (PNG/JPEG) или скана PDF в workspace — вызывай инструмент `ocr_document`.

## Публичные исходники
web_search служит только для поиска: его недоверенные заголовки и snippets не являются источником.
''';

  test('synchronizes when all tools are available', () {
    final result = synchronizer.synchronize(
      prompt: samplePrompt,
      availableTools: {'extract_document', 'ocr_document', 'web_search'},
      toolsSupported: true,
    );

    expect(result, contains('- `ocr_document`: офлайн-распознавание'));
    expect(result, contains('вызывай инструмент `ocr_document`'));
    expect(result, contains('web_search служит только для поиска'));
    expect(result, contains('<environment_tools>'));
    expect(result, contains('`extract_document`'));
    expect(result, contains('`ocr_document`'));
    expect(result, contains('`web_search`'));
  });

  test('prunes/annotates instructions when ocr_document is unavailable', () {
    final result = synchronizer.synchronize(
      prompt: samplePrompt,
      availableTools: {'extract_document', 'web_search'},
      toolsSupported: true,
    );

    expect(result, isNot(contains('- `ocr_document`: офлайн-распознавание')));
    expect(result, isNot(contains('вызывай инструмент `ocr_document`')));
    expect(result, contains('[НЕДОСТУПЕН]'));
    expect(result, contains('Не вызывай ocr_document'));
    expect(result, contains('<environment_tools>'));
    expect(result, contains('`extract_document`'));
    expect(result, contains('`web_search`'));
  });

  test('prunes web_search when not in available tools', () {
    final result = synchronizer.synchronize(
      prompt: samplePrompt,
      availableTools: {'extract_document', 'ocr_document'},
      toolsSupported: true,
    );

    expect(
      result,
      contains(
        'Поисковый инструмент web_search в данный момент не настроен и недоступен',
      ),
    );
    expect(result, isNot(contains('`web_search`')));
  });

  test('disables all tools when toolsSupported is false', () {
    final result = synchronizer.synchronize(
      prompt: samplePrompt,
      availableTools: {'extract_document', 'ocr_document'},
      toolsSupported: false,
    );

    expect(
      result,
      contains(
        'ВНИМАНИЕ: Вызов инструментов (tool calling / function calling) в текущей конфигурации модели ОТКЛЮЧЕН',
      ),
    );
    expect(result, contains('Никакие инструменты недоступны'));
  });
}
