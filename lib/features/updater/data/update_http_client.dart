import 'dart:async';

import 'package:dio/dio.dart';

import '../domain/update_manifest.dart';
import '../domain/update_release.dart';

class UpdateHttpResponse {
  const UpdateHttpResponse({
    required this.uri,
    required this.contentLength,
    required this.stream,
  });

  final Uri uri;
  final int? contentLength;
  final Stream<List<int>> stream;
}

abstract interface class UpdateHttpClient {
  Future<UpdateHttpResponse> get(Uri uri);
}

class DioUpdateHttpClient implements UpdateHttpClient {
  DioUpdateHttpClient([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  static const approvedHosts = {
    'api.github.com',
    'github.com',
    'objects.githubusercontent.com',
    'github-releases.githubusercontent.com',
  };

  final Dio _dio;

  @override
  Future<UpdateHttpResponse> get(Uri uri) async {
    var current = uri;
    for (
      var redirects = 0;
      redirects <= UpdateLimits.maxRedirects;
      redirects++
    ) {
      _validateUri(current);
      final response = await _dio.get<ResponseBody>(
        current.toString(),
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        ),
      );
      final status = response.statusCode!;
      if (status >= 300) {
        final location = response.headers.value('location');
        await response.data?.stream.drain<void>();
        if (location == null || redirects == UpdateLimits.maxRedirects) {
          throw const UpdateException('Invalid or excessive update redirect');
        }
        current = current.resolve(location);
        continue;
      }
      if (status != 200 || response.data == null) {
        throw UpdateException('Update request failed with HTTP $status');
      }
      return UpdateHttpResponse(
        uri: current,
        contentLength: _contentLength(response.headers),
        stream: response.data!.stream,
      );
    }
    throw const UpdateException('Too many update redirects');
  }

  static int? _contentLength(Headers headers) {
    final value = headers.value(Headers.contentLengthHeader);
    return value == null ? null : int.tryParse(value);
  }

  static void _validateUri(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !approvedHosts.contains(uri.host.toLowerCase())) {
      throw const UpdateException('Update URL is not approved');
    }
  }
}
