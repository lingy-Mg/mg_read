/// MgRead LAN 清单投影边界测试。
///
/// 验证 Content Library 中超出 LAN v2 范围的条目不会破坏整个清单，且仅有进度
/// 超限时仍保留书籍元数据。Runtime 在这些测试中不得启动。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('manifest skips unsupported media and invalid identity while retaining a book without invalid progress', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-lan-manifest-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });

    final retained = await library.addLibraryItem(_source('retained-book', '保留的小说', ContentKind.novel));
    await library.saveProgress(
      LibraryReadingProgress(
        itemId: retained.id,
        chapterId: _repeat('c', 2049),
        paragraphId: 'paragraph-1',
        characterOffset: 0,
        chapterIndex: 0,
        chapterFraction: 0,
        bookFraction: 0,
        updatedAtUtc: DateTime.utc(2026, 8, 31),
      ),
    );
    await library.addLibraryItem(_source('audio-1', '音频条目', ContentKind.audio));
    await library.addLibraryItem(_source('video-1', '视频条目', ContentKind.video));
    await library.addLibraryItem(_source(_repeat('r', 2049), '超长身份', ContentKind.novel));

    final manifest = await MgReadLanSyncGateway(library, PluginRuntime()).createPairedManifest(includePlugins: false);

    expect(manifest.shelfItems, hasLength(1));
    expect(manifest.shelfItems.single.remoteContentId, 'retained-book');
    expect(manifest.shelfItems.single.progress, isNull);
    expect(manifest.skippedShelfItems, 3);
    expect(() => LanSyncManifest.fromJson(manifest.toJson()), returnsNormally);
  });

  test('shelf-disabled paired manifest does not report local skipped items', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-lan-empty-manifest-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    await library.addLibraryItem(_source('audio-1', '音频条目', ContentKind.audio));

    final manifest = await MgReadLanSyncGateway(library, PluginRuntime()).createPairedManifest(includePlugins: false, includeShelf: false);

    expect(manifest.shelfItems, isEmpty);
    expect(manifest.skippedShelfItems, 0);
  });
}

BookshelfAddRequest _source(String remoteBookId, String title, ContentKind kind) => BookshelfAddRequest(
  pluginId: 'fixture.source',
  pluginVersion: '1.0.0',
  remoteContentId: remoteBookId,
  title: title,
  author: null,
  kind: kind,
);

String _repeat(String value, int count) => List<String>.filled(count, value).join();
