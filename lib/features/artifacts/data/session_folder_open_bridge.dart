import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens only an existing SAF session directory; never launches a picker.
class SessionFolderOpenBridge {
  const SessionFolderOpenBridge({
    this.channel = const MethodChannel('mobilka/session_folder'),
  });

  final MethodChannel channel;

  Future<bool> open({
    required String treeUri,
    required String sessionKey,
  }) async {
    final uri = Uri.tryParse(treeUri);
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        uri == null ||
        uri.scheme != 'content' ||
        uri.authority.isEmpty ||
        sessionKey.isEmpty ||
        sessionKey == '.' ||
        sessionKey == '..' ||
        sessionKey.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      return false;
    }
    try {
      return await channel.invokeMethod<bool>('openSessionFolder', {
            'treeUri': treeUri,
            'sessionKey': sessionKey,
          }) ==
          true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
