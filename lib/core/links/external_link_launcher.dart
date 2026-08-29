import 'package:url_launcher/url_launcher.dart';

abstract interface class ExternalLinkLauncher {
  Future<bool> launch(Uri uri);
}

class UrlExternalLinkLauncher implements ExternalLinkLauncher {
  const UrlExternalLinkLauncher({this.launchFunction = _launchExternal});

  final Future<bool> Function(Uri, LaunchMode) launchFunction;

  @override
  Future<bool> launch(Uri uri) =>
      launchFunction(uri, LaunchMode.externalApplication);
}

Future<bool> _launchExternal(Uri uri, LaunchMode mode) =>
    launchUrl(uri, mode: mode);
