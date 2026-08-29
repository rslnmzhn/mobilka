import 'dart:convert';
import 'dart:io';

class ExternalLinkPolicy {
  const ExternalLinkPolicy();
  static const maxWireBytes = 8 * 1024;

  Uri? canonicalize(String raw) {
    if (!_safeCharacters(raw)) return null;
    final match = RegExp(
      r'^(https?)://([^/?#]+)(.*)$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return null;
    final scheme = match.group(1)!.toLowerCase();
    final authority = match.group(2)!;
    final tail = match.group(3)!;
    final parsed = _parseAuthority(authority);
    if (parsed == null || !_validHost(parsed.host, parsed.ipv6)) return null;
    final port = parsed.port;
    final includePort =
        port != null &&
        !((scheme == 'http' && port == 80) ||
            (scheme == 'https' && port == 443));
    final host = parsed.ipv6
        ? '[${parsed.host.toLowerCase()}]'
        : parsed.host.toLowerCase();
    final suffix = tail.isEmpty || tail.startsWith('?') || tail.startsWith('#')
        ? '/$tail'
        : tail;
    try {
      final canonical = Uri.parse(
        '$scheme://$host${includePort ? ':$port' : ''}$suffix',
      );
      if (canonical.host.toLowerCase() != parsed.host.toLowerCase()) {
        return null;
      }
      return canonical;
    } on FormatException {
      return null;
    }
  }

  bool _safeCharacters(String raw) =>
      raw.isNotEmpty &&
      utf8.encode(raw).length <= maxWireBytes &&
      !raw.contains('\\') &&
      !RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(raw) &&
      !raw.runes.any((rune) => rune <= 0x20 || rune == 0x7f || rune > 0x7f);

  ({String host, int? port, bool ipv6})? _parseAuthority(String authority) {
    if (authority.isEmpty ||
        authority.contains('@') ||
        authority.contains('%')) {
      return null;
    }
    if (authority.startsWith('[')) {
      final match = RegExp(
        r'^\[([^\]]+)\](?::([0-9]+))?$',
      ).firstMatch(authority);
      if (match == null) return null;
      final port = _port(match.group(2));
      if (match.group(2) != null && port == null) return null;
      return (host: match.group(1)!, port: port, ipv6: true);
    }
    if (authority.contains('[') || authority.contains(']')) return null;
    final colon = authority.lastIndexOf(':');
    final host = colon < 0 ? authority : authority.substring(0, colon);
    final portText = colon < 0 ? null : authority.substring(colon + 1);
    if (host.contains(':')) return null;
    final port = _port(portText);
    if (portText != null && port == null) return null;
    return (host: host, port: port, ipv6: false);
  }

  int? _port(String? value) {
    if (value == null) return null;
    if (!RegExp(r'^[0-9]{1,5}$').hasMatch(value)) return null;
    final port = int.parse(value);
    return port >= 1 && port <= 65535 ? port : null;
  }

  bool _validHost(String host, bool ipv6) {
    if (ipv6) {
      final address = InternetAddress.tryParse(host);
      return address != null && address.type == InternetAddressType.IPv6;
    }
    if (host.isEmpty || host.length > 253 || host.endsWith('.')) return false;
    if (RegExp(r'^[0-9.]+$').hasMatch(host)) return _validIpv4(host);
    if (RegExp(
      r'^(?:0x[0-9a-f]+|0[0-7]+)$',
      caseSensitive: false,
    ).hasMatch(host)) {
      return false;
    }
    final labels = host.split('.');
    return labels.every(
      (label) =>
          label.isNotEmpty &&
          label.length <= 63 &&
          RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$').hasMatch(label),
    );
  }

  bool _validIpv4(String host) {
    final parts = host.split('.');
    return parts.length == 4 &&
        parts.every((part) {
          if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return false;
          return int.parse(part) <= 255;
        });
  }
}
