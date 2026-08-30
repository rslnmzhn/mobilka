class SearxngSearchSettings {
  const SearxngSearchSettings({
    this.enabled = false,
    this.baseUrl = '',
    this.locale = 'en',
    this.timeRange = 'none',
    this.maxResults = 5,
    this.httpAcknowledgedUrl,
    this.hasSecret = false,
  });

  final bool enabled;
  final String baseUrl;
  final String locale;
  final String timeRange;
  final int maxResults;
  final String? httpAcknowledgedUrl;
  final bool hasSecret;

  bool get isHttp => Uri.tryParse(baseUrl)?.scheme == 'http';
  bool get httpAcknowledged => isHttp && httpAcknowledgedUrl == baseUrl;
  bool get usable =>
      enabled &&
      baseUrl.isNotEmpty &&
      (!isHttp || httpAcknowledged) &&
      !(isHttp && hasSecret);
}
