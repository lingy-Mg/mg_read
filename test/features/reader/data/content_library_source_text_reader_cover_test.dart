/// 书架小说进入阅读器的封面交接测试。
///
/// 职责：
/// - 验证普通启动和预热启动都携带 Content Library 封面字节。
///
/// 注意：
/// - 测试只读临时本地缓存，不请求 Runtime 或网络。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';

void main() {
  test('keeps the cached shelf cover on normal and prewarmed novel requests', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-reader-cover-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final coverUrl = Uri.parse('https://covers.example/shelf-novel.png');
    final item = await library.addLibraryItem(
      BookshelfAddRequest(
        title: '封面交接小说',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: 'cover-novel',
        coverUrl: coverUrl,
      ),
    );
    await library.saveCover(
      key: CoverKey(
        pluginId: item.source.pluginId,
        pluginVersion: item.source.pluginVersion,
        remoteContentId: item.source.remoteContentId,
        coverUrl: coverUrl,
      ),
      bytes: const <int>[1, 2, 3, 4],
    );
    await library.syncNovelCatalog(
      itemId: item.id,
      chapters: const <SourceNovelCatalogChapter>[SourceNovelCatalogChapter(remoteIdentity: 'chapter-1', title: '第一章', index: 0)],
    );
    final session = await library.openNovelReaderSession(item.id);
    await session!.cacheChapter(entry: session.initialChapter, text: '已缓存正文');
    final reader = ContentLibrarySourceTextReader(library, const _UnusedGateway());

    final normal = await reader.launch(item.id.value);
    final prewarmed = await reader.warmLocal(item.id.value);

    expect(normal.entryCoverBytes, const <int>[1, 2, 3, 4]);
    expect(prewarmed?.entryCoverBytes, const <int>[1, 2, 3, 4]);
  });
}

final class _UnusedGateway implements SourceContentGateway {
  const _UnusedGateway();

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => throw UnimplementedError();

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
}
