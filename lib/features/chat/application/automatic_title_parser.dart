String? parseAutomaticConversationTitle(String value) {
  var title = value.trim();
  final lines = title
      .split(RegExp(r'[\r\n]+'))
      .where((line) => line.trim().isNotEmpty);
  if (lines.length != 1) return null;
  title = lines.single.trim().replaceAll(RegExp(r'\s+'), ' ');
  if ((title.startsWith('"') && title.endsWith('"')) ||
      (title.startsWith('“') && title.endsWith('”')) ||
      (title.startsWith('«') && title.endsWith('»'))) {
    title = title.substring(1, title.length - 1).trim();
  }
  if (title.isEmpty ||
      title.length > 48 ||
      title.split(' ').length > 6 ||
      RegExp(r'^(title|заголовок)\s*:', caseSensitive: false).hasMatch(title) ||
      RegExp(r'[`#*_~\[\]{}<>]|^[\-+>]\s|[\x00-\x1f\x7f]').hasMatch(title) ||
      RegExp(
        r'^(new conversation|new chat|новый (чат|диалог))$',
        caseSensitive: false,
      ).hasMatch(title)) {
    return null;
  }
  return title;
}
