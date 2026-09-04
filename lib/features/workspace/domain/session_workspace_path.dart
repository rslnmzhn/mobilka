import 'dart:convert';

final class SessionWorkspacePath {
  SessionWorkspacePath._(this.value, this.components);

  static const maxComponents = 16;
  static const maxComponentBytes = 128;
  static const maxPathBytes = 1024;

  final String value;
  final List<String> components;

  static SessionWorkspacePath parse(String source, {bool allowRoot = false}) {
    if (source.isEmpty && allowRoot) {
      return SessionWorkspacePath._('', const []);
    }
    if (source.isEmpty || source.startsWith('/') || source.endsWith('/')) {
      throw const FormatException('workspace_path_invalid');
    }
    if (source.contains(r'\') || source.contains(':')) {
      throw const FormatException('workspace_path_invalid');
    }
    _requireValidUnicode(source);
    final pathBytes = utf8.encode(source).length;
    if (pathBytes > maxPathBytes) {
      throw const FormatException('workspace_path_too_long');
    }
    final parts = source.split('/');
    if (parts.length > maxComponents) {
      throw const FormatException('workspace_path_too_deep');
    }
    for (final part in parts) {
      _validateComponent(part);
    }
    return SessionWorkspacePath._(source, List<String>.unmodifiable(parts));
  }

  static void _validateComponent(String component) {
    if (component.isEmpty || component == '.' || component == '..') {
      throw const FormatException('workspace_path_invalid_component');
    }
    if (utf8.encode(component).length > maxComponentBytes) {
      throw const FormatException('workspace_path_component_too_long');
    }
    if (component.endsWith('.') || component.endsWith(' ')) {
      throw const FormatException('workspace_path_trailing_dot_or_space');
    }
    if (component.startsWith('.')) {
      throw const FormatException('workspace_path_reserved_internal');
    }
    for (final rune in component.runes) {
      if (rune < 0x20 || rune == 0x7f) {
        throw const FormatException('workspace_path_control_character');
      }
    }
    final stem = component.split('.').first.toUpperCase();
    if (_reserved.contains(stem)) {
      throw const FormatException('workspace_path_reserved_name');
    }
  }

  static void _requireValidUnicode(String value) {
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) {
          throw const FormatException('workspace_path_invalid_utf8');
        }
        final low = value.codeUnitAt(index);
        if (low < 0xdc00 || low > 0xdfff) {
          throw const FormatException('workspace_path_invalid_utf8');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('workspace_path_invalid_utf8');
      }
    }
  }

  static const _reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
}
