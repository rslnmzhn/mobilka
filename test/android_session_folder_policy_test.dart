import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android folder bridge opens exact existing SAF document without picker',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/rslnmzhn/mobilka/SessionFolderOpenBridge.kt',
      ).readAsStringSync();
      expect(source, contains('DocumentsContract.buildDocumentUriUsingTree('));
      expect(source, contains('DocumentsContract.getTreeDocumentId(tree)'));
      expect(source, contains('access.existingScope(normalized)'));
      expect(source, contains('Intent(Intent.ACTION_VIEW)'));
      expect(
        source,
        contains(
          'setDataAndType(scope.session, DocumentsContract.Document.MIME_TYPE_DIR)',
        ),
      );
      expect(source, contains('ClipData.newRawUri("session", scope.session)'));
      expect(source, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
      expect(
        source,
        isNot(contains('Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)')),
      );
      expect(source, isNot(contains('mutationScope(')));
      expect(source, isNot(contains('createDirectory(')));
      expect(source, isNot(contains('setDataAndType(scope.tree')));
    },
  );
}
