/// Synchronizes agent prompt tool instructions with actually registered
/// tool schemas in the current runtime/model environment.
///
/// Ensures the model's system prompt never instructs it to call a tool that
/// is absent from the request's function-calling tool definitions.
class ToolInstructionSynchronizer {
  const ToolInstructionSynchronizer();

  static const allKnownTools = <String>{
    'update_memory_file',
    'generate_docx',
    'switch_persona',
    'list_personas',
    'save_persona',
    'delete_persona',
    'read_skill',
    'list_skills',
    'propose_skill',
    'write_session_notes',
    'read_session_notes',
    'list_files',
    'search_files',
    'read_file',
    'write_file',
    'apply_patch',
    'move_file',
    'delete_file',
    'make_directory',
    'read_public_source',
    'web_search',
    'extract_document',
    'ocr_document',
  };

  /// Synchronizes [prompt] with [availableTools].
  ///
  /// - If [toolsSupported] is false or [availableTools] is empty, appends a notice
  ///   that tool calling is disabled for this model.
  /// - Annotates or adjusts instructions for specific tools that are missing from
  ///   [availableTools].
  /// - Appends a definitive `<environment_tools>` section listing the exact
  ///   executable tools.
  String synchronize({
    required String prompt,
    required Set<String> availableTools,
    bool toolsSupported = true,
  }) {
    if (prompt.trim().isEmpty) return prompt;

    if (!toolsSupported || availableTools.isEmpty) {
      return '$prompt\n\n'
          '<environment_tools>\n'
          'ВНИМАНИЕ: Вызов инструментов (tool calling / function calling) в текущей конфигурации модели ОТКЛЮЧЕН. '
          'Никакие инструменты недоступны. Отвечай исключительно обычным текстом, не пытайся формировать вызовы функций или tool_calls.\n'
          '</environment_tools>';
    }

    var synchronizedPrompt = prompt;

    // Synchronize ocr_document
    if (!availableTools.contains('ocr_document')) {
      synchronizedPrompt = synchronizedPrompt.replaceAll(
        RegExp(r'-\s*`ocr_document`:[^\n]+(\n\s+[^\n]+)*', multiLine: true),
        '- `ocr_document`: [НЕДОСТУПЕН] Функция распознавания текста (OCR) недоступна в текущем окружении (отсутствует рабочий нативный воркер OCR). Не вызывай ocr_document; если пользователь просит распознать текст с изображения, сообщи о недоступности OCR на данном устройстве.',
      );
      synchronizedPrompt = synchronizedPrompt.replaceAll(
        RegExp(
          r'-\s*Если пользователю нужно распознать текст[^\n]+(\n\s+[^\n]+)*',
          multiLine: true,
        ),
        '- Распознавание текста: инструмент ocr_document отключён в текущей среде, вежливо предупреди пользователя о недоступности OCR на данном устройстве.',
      );
      synchronizedPrompt = synchronizedPrompt.replaceAll(
        RegExp(
          r'-\s*Если `extract_document` для PDF вернул пустой текст[^\n]+(\n\s+[^\n]+)*',
          multiLine: true,
        ),
        '',
      );
    }

    // Synchronize extract_document
    if (!availableTools.contains('extract_document')) {
      synchronizedPrompt = synchronizedPrompt.replaceAll(
        RegExp(r'-\s*`extract_document`:[^\n]+(\n\s+[^\n]+)*', multiLine: true),
        '- `extract_document`: [НЕДОСТУПЕН] Извлечение документов отключено в текущей среде. Не вызывай extract_document.',
      );
    }

    // Synchronize web_search
    if (!availableTools.contains('web_search')) {
      synchronizedPrompt = synchronizedPrompt.replaceAll(
        RegExp(
          r'web_search служит только для поиска:[^\n]+(\n\s+[^\n]+)*',
          multiLine: true,
        ),
        'Поисковый инструмент web_search в данный момент не настроен и недоступен. Не пытайся вызывать web_search.',
      );
    }

    // Append definitive available tools manifest
    final sortedTools = availableTools.toList()..sort();
    final toolsList = sortedTools.map((t) => '`$t`').join(', ');

    return '$synchronizedPrompt\n\n'
        '<environment_tools>\n'
        'Фактически доступные инструменты для вызова в этой сессии: $toolsList.\n'
        'Инструменты, отсутствующие в этом перечне, технически недоступны. Никогда не пытайся вызывать инструменты, которых нет в этом списке!\n'
        '</environment_tools>';
  }
}
