import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobilka/features/artifacts/data/session_folder_open_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mobilka/session_folder');
  const bridge = SessionFolderOpenBridge();
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'passes exact current session and SAF tree, not a root open request',
    () async {
      expect(
        await bridge.open(
          treeUri: 'content://docs/tree/root',
          sessionKey: 'current-session',
        ),
        isTrue,
      );
      expect(calls.single.method, 'openSessionFolder');
      expect(calls.single.arguments, {
        'treeUri': 'content://docs/tree/root',
        'sessionKey': 'current-session',
      });
    },
  );

  test(
    'rejects missing session, traversal and local paths before native call',
    () async {
      for (final key in [
        '',
        '.',
        '..',
        '../other',
        'other/session',
        'other\\session',
        'bad\u0000key',
      ]) {
        expect(
          await bridge.open(
            treeUri: 'content://docs/tree/root',
            sessionKey: key,
          ),
          isFalse,
        );
      }
      expect(
        await bridge.open(treeUri: '/storage/root', sessionKey: 'current'),
        isFalse,
      );
      expect(calls, isEmpty);
    },
  );

  test('unsupported platform fails without external launch', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(
      await bridge.open(
        treeUri: 'content://docs/tree/root',
        sessionKey: 'current',
      ),
      isFalse,
    );
    expect(calls, isEmpty);
  });

  test('native failure and missing plugin fail closed', () async {
    for (final error in [
      PlatformException(code: 'session_missing'),
      MissingPluginException(),
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => throw error);
      expect(
        await bridge.open(
          treeUri: 'content://docs/tree/root',
          sessionKey: 'current',
        ),
        isFalse,
      );
    }
  });
}
