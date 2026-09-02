import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../domain/update_release.dart';

const updateManifestPublicKeyBase64 =
    'nH/Hnmn7UJtCy4Qb91c9dIAwQ3LSUkv6yRhDhMlZ3JY=';

abstract interface class ManifestSignatureVerifier {
  Future<bool> verify(List<int> message, List<int> signature);
}

class Ed25519ManifestVerifier implements ManifestSignatureVerifier {
  const Ed25519ManifestVerifier();

  @override
  Future<bool> verify(List<int> message, List<int> signature) async {
    final key = _strictBase64(updateManifestPublicKeyBase64, 32);
    return Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
  }

  static List<int> _strictBase64(String value, int length) {
    try {
      final decoded = base64.decode(value);
      if (decoded.length != length || base64.encode(decoded) != value) {
        throw const FormatException();
      }
      return decoded;
    } on FormatException {
      throw const UpdateException('Invalid public key encoding');
    }
  }
}
