import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/artifacts/domain/artifact_link.dart';

void main() {
  test('accepts and roundtrips canonical representations', () {
    for (final representation in ArtifactRepresentation.values) {
      final value = ArtifactLink(
        artifactId: '123-artifact',
        representation: representation,
      ).toString();
      expect(ArtifactLink.tryParse(value)?.toString(), value);
    }
  });

  test('rejects noncanonical and unsafe forms', () {
    final rejected = [
      '',
      'MOBILKA-ARTIFACT:123-artifact?representation=md',
      'mobilka-artifact://123-artifact?representation=md',
      'mobilka-artifact:/123-artifact?representation=md',
      r'mobilka-artifact:123\artifact?representation=md',
      'mobilka-artifact:123 artifact?representation=md',
      'mobilka-artifact:123%2Dartifact?representation=md',
      'mobilka-artifact:123-artifact',
      'mobilka-artifact:123-artifact?representation=pdf',
      'mobilka-artifact:123-artifact?representation=md&x=1',
      'mobilka-artifact:123-artifact?representation=md&representation=md',
      'mobilka-artifact:123-artifact?representation=md#x',
      'mobilka-artifact:артефакт?representation=md',
      'mobilka-artifact:123-artifact?representation=md\u0000',
      'x' * 257,
    ];
    for (final value in rejected) {
      expect(ArtifactLink.tryParse(value), isNull, reason: value);
    }
  });

  test('claims malformed case variants for internal dispatch', () {
    expect(
      ArtifactLink.claimsScheme(
        'Mobilka-Artifact:123-artifact?representation=md',
      ),
      true,
    );
    expect(ArtifactLink.claimsScheme('https://example.com'), false);
    expect(ArtifactLink.claimsScheme('mobilka-artifact malformed'), true);
  });
}
