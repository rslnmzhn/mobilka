import '../../public_source/application/public_source_policy.dart';

class WebSearchFailure implements Exception {
  const WebSearchFailure(this.code);
  final String code;
}

class WebSearchPolicy {
  const WebSearchPolicy(this.targetPolicy);
  final PublicTargetPolicy targetPolicy;

  Future<ValidatedPublicTarget> validate(String url) async {
    try {
      return await targetPolicy.validate(url);
    } on PublicSourceFailure catch (error) {
      throw WebSearchFailure(error.code);
    }
  }

  static String validateBaseUrl(String raw) {
    if (raw.length > 8192 ||
        raw.codeUnits.any((c) => c > 127) ||
        raw.contains(RegExp(r'[\x00-\x20\\]'))) {
      throw const WebSearchFailure('invalid_endpoint');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.hasQuery ||
        uri.host.endsWith('.') ||
        (uri.hasPort && uri.port != 80 && uri.port != 443)) {
      throw const WebSearchFailure('invalid_endpoint');
    }
    final canonical = PublicTargetPolicy.canonicalize(
      uri.replace(path: uri.path.isEmpty ? '/' : uri.path),
    );
    return canonical.toString().replaceFirst(RegExp(r'/$'), '');
  }

  static Uri searchUri(String base, Map<String, String> query) {
    final endpoint = Uri.parse(validateBaseUrl(base));
    final path = '${endpoint.path == '/' ? '' : endpoint.path}/search';
    return endpoint.replace(path: path, queryParameters: query);
  }
}

String validateSearchLocale(Object? value) {
  if (value is! String ||
      value.length > 32 ||
      !RegExp(r'^[A-Za-z]{2,3}(?:[-_][A-Za-z]{2,4})?$').hasMatch(value)) {
    throw const WebSearchFailure('invalid_locale');
  }
  return value;
}

String validateSearchTimeRange(Object? value) {
  if (value is! String ||
      !const {'none', 'day', 'week', 'month', 'year'}.contains(value)) {
    throw const WebSearchFailure('invalid_time_range');
  }
  return value;
}
