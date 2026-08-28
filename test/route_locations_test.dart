import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/core/router/route_locations.dart';

void main() {
  test('session artifact conversation id is one encoded path segment', () {
    final location = sessionArtifactsLocation('a/b ?#% ü');
    expect(location, '/chat/a%2Fb%20%3F%23%25%20%C3%BC/artifacts');
    final uri = Uri.parse(location);
    expect(uri.pathSegments, ['chat', 'a/b ?#% ü', 'artifacts']);
  });
}
