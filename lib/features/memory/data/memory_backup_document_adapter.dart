import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:saf/saf.dart';

import '../application/memory_backup_codec.dart';

abstract interface class MemoryBackupDocumentAdapter {
  Future<String?> importDocument();
  Future<bool> exportDocument(String document);
}

class PlatformMemoryBackupDocumentAdapter
    implements MemoryBackupDocumentAdapter {
  PlatformMemoryBackupDocumentAdapter({Saf? saf}) : _saf = saf ?? Saf();

  final Saf _saf;
  static const _types = [
    XTypeGroup(
      label: 'mobilka memory backup',
      extensions: ['json'],
      mimeTypes: ['application/json'],
    ),
  ];

  @override
  Future<bool> exportDocument(String document) async {
    if (Platform.isAndroid) {
      final directory = await _saf.pickDirectory();
      if (directory == null) return false;
      final date = DateTime.now().toUtc().toIso8601String().split('T').first;
      await _saf.writeFileBytes(
        directory.uri,
        'mobilka-memory-$date.${MemoryBackupCodec.documentExtension}',
        'application/json',
        Uint8List.fromList(utf8.encode(document)),
      );
      return true;
    }

    final location = await getSaveLocation(
      acceptedTypeGroups: _types,
      suggestedName: 'mobilka-memory.${MemoryBackupCodec.documentExtension}',
    );
    if (location == null) return false;
    await File(location.path).writeAsString(document, flush: true);
    return true;
  }

  @override
  Future<String?> importDocument() async {
    if (Platform.isAndroid) {
      final file = await _saf.pickFile(
        mimeTypes: const ['application/json', 'text/plain'],
      );
      if (file == null) return null;
      final bytes = await _saf.readFileBytes(
        file.uri,
        count: MemoryBackupCodec.maxDocumentBytes + 1,
      );
      return _decodeBounded(bytes);
    }

    final file = await openFile(acceptedTypeGroups: _types);
    if (file == null) return null;
    if (await file.length() > MemoryBackupCodec.maxDocumentBytes) {
      throw const MemoryBackupFormatException('Backup document is too large');
    }
    return _decodeBounded(await file.readAsBytes());
  }

  static String _decodeBounded(Uint8List bytes) {
    if (bytes.length > MemoryBackupCodec.maxDocumentBytes) {
      throw const MemoryBackupFormatException('Backup document is too large');
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const MemoryBackupFormatException('Backup is not valid UTF-8');
    }
  }
}
