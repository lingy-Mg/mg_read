/// Verifies retired local records are removed on reopen without changing shelf
/// content or unrelated metadata, and shelf operations no longer produce them.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
// Use Drift's SQLite engine to inspect retired records without a legacy codec.
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('reopen removes retired records and preserves shelf and unrelated metadata', () async {
    final root = await Directory.systemTemp.createTemp('mgread-retired-records-');
    addTearDown(() => root.delete(recursive: true));
    final library = await ContentLibrary.open(dataRoot: root);
    late LibraryItem item;
    try {
      item = await library.addLibraryItem(
        const BookshelfAddRequest(
          title: '保留的书',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'fixture',
          pluginVersion: '1.0.0',
          remoteContentId: 'retained-book',
        ),
      );
    } finally {
      await library.close();
    }

    final path = '${root.path}/app_metadata.sqlite';
    final seed = sqlite3.open(path);
    try {
      expect(seed.select('SELECT record_id FROM metadata_records'), isEmpty);
      for (final (id, kind, scopeKind, scopeId) in [
        ('old-notice', 'content_library_notification', 'content_library', 'default'),
        ('other-setting', 'app_setting', 'local', 'primary'),
        ('other-scope', 'content_library_notification', 'other', 'default'),
      ]) {
        seed.execute(
          'INSERT INTO metadata_records(record_id,record_kind,scope_kind,scope_id,format_version,revision,payload_json,created_at_utc,updated_at_utc) '
          'VALUES(?,?,?,?,1,1,?,0,0)',
          [id, kind, scopeKind, scopeId, '{}'],
        );
      }
    } finally {
      seed.close();
    }

    final reopened = await ContentLibrary.open(dataRoot: root);
    try {
      expect((await reopened.loadShelfProjection()).single.title, item.title);
      await reopened.removeLibraryItem(item.id, LibraryRemovalPolicy.removeFromShelfKeepContent);
      expect((await reopened.getLibraryItem(item.id))?.state, 'retained');
    } finally {
      await reopened.close();
    }

    final inspected = sqlite3.open(path);
    try {
      expect(inspected.select('SELECT record_id FROM metadata_records ORDER BY record_id').map((row) => row['record_id']), [
        'other-scope',
        'other-setting',
      ]);
    } finally {
      inspected.close();
    }
  });
}
