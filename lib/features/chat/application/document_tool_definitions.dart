import '../domain/chat_tool.dart';

const _sourceProperties = <String, Object?>{
  'path': {
    'type': 'string',
    'minLength': 1,
    'maxLength': 1024,
    'description':
        'Session-relative file path; must match the captured source.',
  },
  'source_sha256': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
};

const _pageProperties = <String, Object?>{
  'first_page': {'type': 'integer', 'minimum': 1, 'maximum': 100, 'default': 1},
  'page_count': {'type': 'integer', 'minimum': 1, 'maximum': 25, 'default': 1},
};

const documentToolDefinitions = <ChatToolDefinition>[
  ChatToolDefinition(
    name: 'extract_document',
    effect: ChatToolEffect.readOnly,
    description:
        'Extract local CSV (comma-delimited), DOCX or XLSX into an undisclosed '
        'local result. PDF text requires explicitly ready native processing. '
        'Never runs OCR or publishes text. Page options are PDF-only; '
        'first_page + page_count must not exceed 101. Disclosure requires '
        'a separate persisted confirmation before model text.',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'required': ['path', 'source_sha256', 'format'],
      'properties': {
        ..._sourceProperties,
        'format': {
          'type': 'string',
          'enum': ['csv', 'docx', 'xlsx', 'pdf'],
        },
        ..._pageProperties,
      },
    },
  ),
  ChatToolDefinition(
    name: 'ocr_document',
    effect: ChatToolEffect.readOnly,
    description:
        'Explicit offline OCR of PNG, JPEG or scanned PDF only, with fixed '
        'Russian + English recognition and explicitly ready native processing. '
        'Returns an undisclosed local result, never model text. Images require '
        'first_page=1 and page_count=1; PDF first_page + page_count must not '
        'exceed 101. Disclosure requires separate persisted confirmation.',
    parameters: {
      'type': 'object',
      'additionalProperties': false,
      'required': ['path', 'source_sha256', 'format'],
      'properties': {
        ..._sourceProperties,
        'format': {
          'type': 'string',
          'enum': ['png', 'jpeg', 'pdf'],
        },
        'language': {
          'type': 'string',
          'enum': ['engRus'],
          'default': 'engRus',
        },
        ..._pageProperties,
      },
    },
  ),
];
