import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'dart:io';
import 'package:mobilka/features/chat/data/chat_api_client.dart';
import 'package:mobilka/features/chat/data/chat_repository.dart';
import 'package:mobilka/features/chat/domain/chat_message.dart';
import 'package:mobilka/features/memory/application/context_injector.dart';
import 'package:mobilka/features/settings/data/settings_repository.dart';

void main() {
  late FlutterSecureStoragePlatform originalPlatform;
  late Directory directory;

  setUp(() async {
    originalPlatform = FlutterSecureStoragePlatform.instance;
    directory = Directory.systemTemp.createTempSync('chat-preparation-');
    Hive.init(directory.path);
    await Hive.openBox<dynamic>('preferences');
  });

  tearDown(() async {
    FlutterSecureStoragePlatform.instance = originalPlatform;
    await Hive.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'wraps secure-storage UnsupportedError as load_settings phase',
    () async {
      FlutterSecureStoragePlatform.instance = _ThrowingSecureStoragePlatform();
      final repository = ChatRepository(
        ChatApiClient(Dio()),
        SettingsRepository(const FlutterSecureStorage()),
        ContextInjector(_MemorySource(), _AgentSource(), () async => null),
      );

      await expectLater(
        repository
            .streamCompletion(
              model: 'model',
              messages: [
                ChatMessage(
                  id: '1',
                  role: ChatRole.user,
                  content: 'hi',
                  createdAt: DateTime.utc(2026),
                ),
              ],
              cancelToken: CancelToken(),
            )
            .drain<void>(),
        throwsA(
          isA<ChatPreparationException>()
              .having((error) => error.phase, 'phase', 'load_settings')
              .having(
                (error) => error.cause,
                'cause',
                isA<SettingsSecretUnavailableException>(),
              ),
        ),
      );
    },
  );

  test('wraps context UnsupportedError as inject_context phase', () async {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
    final repository = ChatRepository(
      ChatApiClient(Dio()),
      SettingsRepository(const FlutterSecureStorage()),
      ContextInjector(
        _MemorySource(error: UnsupportedError('context unavailable')),
        _AgentSource(),
        () async => null,
      ),
    );

    await expectLater(
      repository
          .streamCompletion(
            model: 'model',
            messages: [
              ChatMessage(
                id: '1',
                role: ChatRole.user,
                content: 'hi',
                createdAt: DateTime.utc(2026),
              ),
            ],
            cancelToken: CancelToken(),
          )
          .drain<void>(),
      throwsA(
        isA<ChatPreparationException>()
            .having((error) => error.phase, 'phase', 'inject_context')
            .having((error) => error.cause, 'cause', isA<UnsupportedError>()),
      ),
    );
  });
}

class _ThrowingSecureStoragePlatform extends TestFlutterSecureStoragePlatform {
  _ThrowingSecureStoragePlatform() : super({});

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    throw UnsupportedError('unsupported_platform');
  }
}

class _MemorySource implements MemoryContextSource {
  _MemorySource({this.error});
  final Object? error;

  @override
  Future<Map<String, String>> readSnapshot(Iterable<String> fileNames) async {
    if (error case final value?) throw value;
    return const {};
  }
}

class _AgentSource implements AgentPromptSource {
  @override
  Future<String?> readActivePrompt() async => null;
}
