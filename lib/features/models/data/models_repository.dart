import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/network/endpoint_policy.dart';
import '../../../core/storage/app_boxes.dart';
import '../../settings/data/settings_repository.dart';
import '../domain/ai_model.dart';

part 'models_repository.g.dart';

@Riverpod(keepAlive: true)
ModelsRepository modelsRepository(Ref ref) => ModelsRepository(
  Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))),
  ref.watch(settingsRepositoryProvider),
);

class ModelsRepository {
  ModelsRepository(this._dio, this._settings);
  final Dio _dio;
  final SettingsRepository _settings;

  Future<List<AiModel>> discover() async {
    final settings = await _settings.load();
    final key = await _settings.readApiKey();
    final endpoint = endpointResourceUri(settings.baseUrl, 'models');
    final headers = endpointAuthorizationHeaders(
      endpoint: endpoint,
      apiKey: key,
    );
    final response = await _dio.get<Map<String, dynamic>>(
      endpoint.toString(),
      options: Options(
        headers: headers,
        followRedirects: endpointRequestMayFollowRedirects(headers),
      ),
    );
    final data = response.data?['data'];
    if (data is! List) {
      throw const FormatException('Endpoint returned an invalid model list');
    }
    final models =
        data
            .whereType<Map>()
            .map(
              (item) => AiModel(
                id: item['id']?.toString() ?? '',
                ownedBy: item['owned_by']?.toString(),
              ),
            )
            .where((model) => model.id.isNotEmpty)
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    await modelsBox.put(
      'cache',
      models
          .map((model) => {'id': model.id, 'ownedBy': model.ownedBy})
          .toList(),
    );
    return models;
  }

  List<AiModel> cached() {
    final raw = modelsBox.get('cache', defaultValue: <dynamic>[]) as List;
    return raw
        .whereType<Map>()
        .map(
          (item) => AiModel(
            id: item['id'].toString(),
            ownedBy: item['ownedBy']?.toString(),
          ),
        )
        .toList();
  }

  Set<String> favorites() =>
      Set<String>.from(modelsBox.get('favorites', defaultValue: <String>[]));
  Set<String> hidden() =>
      Set<String>.from(modelsBox.get('hidden', defaultValue: <String>[]));

  Future<void> setFavorites(Set<String> values) =>
      modelsBox.put('favorites', values.toList());
  Future<void> setHidden(Set<String> values) =>
      modelsBox.put('hidden', values.toList());
}
