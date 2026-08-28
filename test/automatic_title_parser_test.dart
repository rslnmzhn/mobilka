import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/chat/application/automatic_title_parser.dart';

void main() {
  test('accepts concise English and Russian titles', () {
    expect(
      parseAutomaticConversationTitle('"Plan Paris Trip"'),
      'Plan Paris Trip',
    );
    expect(
      parseAutomaticConversationTitle('«План поездки в Париж»'),
      'План поездки в Париж',
    );
  });

  test(
    'rejects multiline, prefixed, markdown, generic and oversized titles',
    () {
      expect(parseAutomaticConversationTitle('First\nSecond'), isNull);
      expect(parseAutomaticConversationTitle('Title: First'), isNull);
      expect(parseAutomaticConversationTitle('# First'), isNull);
      expect(parseAutomaticConversationTitle('New conversation'), isNull);
      expect(
        parseAutomaticConversationTitle('one two three four five six seven'),
        isNull,
      );
    },
  );
}
