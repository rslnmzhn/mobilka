import 'dart:io';

class PublicSourceFailure implements Exception {
  const PublicSourceFailure(this.code);
  final String code;
}

abstract interface class PublicSourceResolver {
  Future<List<InternetAddress>> resolve(String host);
}

class SystemPublicSourceResolver implements PublicSourceResolver {
  const SystemPublicSourceResolver();
  @override
  Future<List<InternetAddress>> resolve(String host) =>
      InternetAddress.lookup(host);
}

class ValidatedPublicTarget {
  const ValidatedPublicTarget(this.uri, this.addresses);
  final Uri uri;
  final List<InternetAddress> addresses;
}

class PublicSourcePolicy {
  static const maxCanonicalUrlBytes = 8 * 1024;
  const PublicSourcePolicy(this.resolver);
  final PublicSourceResolver resolver;

  Future<ValidatedPublicTarget> validate(String rawUrl) async {
    final uri = _parse(rawUrl);
    final canonical = canonicalize(uri);
    late final List<InternetAddress> addresses;
    try {
      addresses = await resolver.resolve(canonical.host);
    } on Object {
      throw const PublicSourceFailure('dns_failed');
    }
    if (addresses.isEmpty ||
        addresses.any((item) => !isGloballyRoutable(item))) {
      throw const PublicSourceFailure('destination_blocked');
    }
    return ValidatedPublicTarget(canonical, List.unmodifiable(addresses));
  }

  static Uri _parse(String raw) {
    if (raw.length > maxCanonicalUrlBytes ||
        raw.codeUnits.any((unit) => unit > 127)) {
      throw const PublicSourceFailure('invalid_url');
    }
    if (raw.contains(RegExp(r'[\x00-\x20\\]'))) {
      throw const PublicSourceFailure('invalid_url');
    }
    late final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      throw const PublicSourceFailure('invalid_url');
    }
    if (uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.host.endsWith('.')) {
      throw const PublicSourceFailure('invalid_url');
    }
    return uri;
  }

  static Uri canonicalize(Uri uri) {
    final literal = InternetAddress.tryParse(uri.host);
    final canonical = uri
        .replace(
          scheme: 'https',
          host: literal?.address ?? uri.host.toLowerCase(),
          port: uri.hasPort && uri.port != 443 ? uri.port : null,
          path: uri.path.isEmpty ? '/' : uri.path,
        )
        .normalizePath();
    if (canonical.toString().length > maxCanonicalUrlBytes) {
      throw const PublicSourceFailure('invalid_url');
    }
    return canonical;
  }

  static bool isGloballyRoutable(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) return _publicV4(bytes);
    if (bytes.length != 16) return false;
    if (_in(bytes, '::ffff:0:0', 96)) return _publicV4(bytes.sublist(12));
    if (!_in(bytes, '2000::', 3)) return false;
    for (final range in _blockedV6) {
      if (_in(bytes, range.$1, range.$2)) return false;
    }
    return true;
  }

  static bool _publicV4(List<int> bytes) {
    for (final range in _blockedV4) {
      if (_in(bytes, range.$1, range.$2)) return false;
    }
    return true;
  }

  static bool _in(List<int> value, String network, int prefix) {
    final base = InternetAddress(network).rawAddress;
    if (base.length != value.length) return false;
    final whole = prefix ~/ 8;
    final remainder = prefix % 8;
    for (var i = 0; i < whole; i++) {
      if (value[i] != base[i]) return false;
    }
    if (remainder == 0) return true;
    final mask = 0xff << (8 - remainder) & 0xff;
    return value[whole] & mask == base[whole] & mask;
  }

  static const _blockedV4 = <(String, int)>[
    ('0.0.0.0', 8),
    ('10.0.0.0', 8),
    ('100.64.0.0', 10),
    ('127.0.0.0', 8),
    ('169.254.0.0', 16),
    ('172.16.0.0', 12),
    ('192.0.0.0', 24),
    ('192.0.2.0', 24),
    ('192.88.99.0', 24),
    ('192.168.0.0', 16),
    ('198.18.0.0', 15),
    ('198.51.100.0', 24),
    ('203.0.113.0', 24),
    ('224.0.0.0', 4),
    ('240.0.0.0', 4),
  ];

  static const _blockedV6 = <(String, int)>[
    ('2001::', 23), // protocol assignments, benchmarking, ORCHIDv2
    ('2001:db8::', 32), // documentation
    ('2002::', 16), // deprecated 6to4 translation
    ('3fff::', 20), // documentation
    ('5f00::', 16), // segment-routing special use
  ];
}
