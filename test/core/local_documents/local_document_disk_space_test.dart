import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/local_documents/local_document_disk_space.dart';

void main() {
  test('queries available space for a directory with spaces and non-ASCII characters', () async {
    final directory = await Directory.systemTemp.createTemp('mg read 可用空间 ');
    addTearDown(() => directory.delete(recursive: true));

    final available = await availableLocalDocumentBytes(directory);

    expect(available, isNotNull);
    expect(available, greaterThan(0));
  });
}
