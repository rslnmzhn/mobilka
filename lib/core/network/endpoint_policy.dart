String validateEndpointBaseUrl(String baseUrl) {
  final normalized = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(normalized);
  final validScheme = uri?.scheme == 'https' || uri?.scheme == 'http';
  if (uri == null ||
      !validScheme ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasQuery) {
    throw const FormatException('Invalid endpoint URL');
  }
  return normalized;
}

Uri endpointResourceUri(String baseUrl, String resource) {
  final endpoint = Uri.parse(validateEndpointBaseUrl(baseUrl));
  return endpoint.replace(
    pathSegments: [
      ...endpoint.pathSegments.where((segment) => segment.isNotEmpty),
      ...resource.split('/').where((segment) => segment.isNotEmpty),
    ],
  );
}

Map<String, String> endpointAuthorizationHeaders({
  required Uri endpoint,
  required String? apiKey,
}) {
  if (apiKey == null || apiKey.isEmpty) {
    return const {};
  }
  return {'Authorization': 'Bearer $apiKey'};
}

bool endpointRequestMayFollowRedirects(Map<String, String> headers) {
  return !headers.containsKey('Authorization');
}
