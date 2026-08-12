import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:saf/saf.dart';

import '../../../core/storage/app_boxes.dart';
import '../application/context_injector.dart';
import 'memory_file_store.dart';

abstract interface class SafMemoryReader {
  Future<String?> readChild(String directoryUri, String fileName);
}

class SafMemoryReaderAdapter implements SafMemoryReader {
  SafMemoryReaderAdapter(this._saf);
  final Saf _saf;

  @override
  Future<String?> readChild(String directoryUri, String fileName) async {
    final children = await _saf.list(directoryUri);
    final file = children
        .where((item) => !item.isDir && item.name == fileName)
        .firstOrNull;
    if (file == null) return null;
    return utf8.decode(await _saf.readFileBytes(file.uri));
  }
}

class StoredMemoryContextSource implements MemoryContextSource {
  StoredMemoryContextSource(this._safReader);

  final SafMemoryReader _safReader;

  @override
  Future<String?> read(String fileName) async {
    final value = preferencesBox.get('memoryLocation') as String?;
    if (value == null) return null;
    final isUri =
        preferencesBox.get('memoryLocationIsUri', defaultValue: false) as bool;
    try {
      return await (isUri
          ? _safReader.readChild(value, fileName)
          : PathMemoryFileStore(value).read(fileName));
    } on Object {
      return null;
    }
  }
}

typedef AssetTextLoader = Future<String> Function(String path);

class AssetAgentPromptSource implements AgentPromptSource {
  AssetAgentPromptSource({AssetTextLoader? loader})
    : _loader = loader ?? rootBundle.loadString;

  final AssetTextLoader _loader;

  @override
  Future<String?> readActivePrompt() async {
    final assetPath =
        preferencesBox.get(
              'activeAgentAsset',
              defaultValue: 'assets/agents/general-assistant.md',
            )
            as String;
    try {
      return await _loader(assetPath);
    } on FlutterError {
      return null;
    }
  }
}
