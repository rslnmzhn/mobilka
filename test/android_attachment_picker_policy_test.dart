import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android attachments copy off UI thread with progress and bounded input',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/rslnmzhn/mobilka/MainActivity.kt',
      ).readAsStringSync();
      expect(source, contains('copyExecutor.execute'));
      expect(source, contains('copyExecutor.shutdown()'));
      expect(source, contains('invokeMethod("loadingImage"'));
      expect(source, contains('File.createTempFile("picked_"'));
      expect(source, contains('total > 64L * 1024 * 1024'));
      expect(source, contains('createdFiles.forEach { it.delete() }'));
      expect(source, contains('Intent(Intent.ACTION_OPEN_DOCUMENT)'));
      expect(source, contains('putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)'));
      final gallery = source.substring(
        source.indexOf('private fun pickImagesFromGallery'),
        source.indexOf('override fun onActivityResult'),
      );
      expect(gallery, contains('Intent.ACTION_PICK'));
      expect(gallery, isNot(contains('ACTION_OPEN_DOCUMENT')));
      expect(gallery, isNot(contains('ACTION_GET_CONTENT')));
    },
  );
}
