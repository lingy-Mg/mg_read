/// Content Library 漫画正文图片缓存统计网关测试。
///
/// 职责：
/// - 验证总量与逐漫画缓存用量映射。
/// - 验证书架中尚无缓存的漫画仍以 0 B 出现在统计中。
///
/// 注意：
/// - 使用独立临时数据目录，不读取真实书架或缓存。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/cache/data/content_library_manga_image_cache_gateway.dart';

void main() {
  test('maps total usage to every bookshelf manga', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-manga-cache-usage-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final cached = await library.addLibraryItem(_request('有缓存漫画', ContentKind.manga, 'cached'));
    await library.addLibraryItem(_request('零缓存漫画', ContentKind.manga, 'empty'));
    await library.addLibraryItem(_request('小说不应出现', ContentKind.novel, 'novel'));
    await library.saveMangaImage(
      itemId: cached.id,
      chapterId: 'chapter-1',
      pageId: 'page-1',
      contentVersion: 1,
      bytes: const <int>[1, 2, 3],
      mimeType: 'image/png',
    );

    final gateway = ContentLibraryMangaImageCacheGateway(() async => library);
    final usage = await gateway.loadUsage();

    expect(usage.totalBytes, 3);
    expect(usage.unattributedBytes, 0);
    expect(usage.entries, hasLength(2));
    expect(usage.entries.singleWhere((entry) => entry.title == '有缓存漫画').bytes, 3);
    expect(usage.entries.singleWhere((entry) => entry.title == '零缓存漫画').bytes, 0);
    expect(usage.entries.where((entry) => entry.title == '小说不应出现'), isEmpty);
  });
}

BookshelfAddRequest _request(String title, ContentKind kind, String id) =>
    BookshelfAddRequest(title: title, author: null, kind: kind, pluginId: 'fixture', pluginVersion: '1.0.0', remoteContentId: id);
