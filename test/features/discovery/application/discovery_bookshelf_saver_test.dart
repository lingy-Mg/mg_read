import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

void main() {
  test('saves a typed discovery item in the app-owned bookshelf', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-discovery-save-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final source = PluginSourceDescriptor(
      id: 'org.example.source',
      displayName: '测试数据源',
      pluginVersion: '2.4.0',
      contentKinds: <PluginContentKind>[PluginContentKind.novel],
    );
    final content = PluginContentSummary(
      id: 'opaque-content-id',
      title: '来自发现页的书',
      contentKind: PluginContentKind.novel,
      author: '测试作者',
      url: null,
      coverUrl: Uri.parse('https://cdn.example.com/covers/opaque.jpg'),
      description: '完整简介',
      language: 'zh-CN',
      status: PluginContentStatus.ongoing,
      access: PluginAccessKind.free,
      wordCount: 5652000,
      chapterCount: 999,
      publishedAt: DateTime.utc(2025, 1, 2),
      updatedAt: DateTime.utc(2026, 8, 27),
      latestChapter: PluginLatestChapter(
        id: 'chapter-999',
        title: '第999章',
        url: Uri.parse('https://source.example/chapter-999'),
        updatedAt: DateTime.utc(2026, 8, 27, 14, 42),
      ),
      categories: const <String>['都市小说'],
      tags: const <String>['NPC'],
      attributes: const <PluginContentAttribute>[PluginContentAttribute(key: 'heat', label: '热度', value: '565.2万')],
    );
    final saver = ContentLibraryDiscoveryBookshelfSaver(library);

    await saver.save(source: source, content: content);
    await saver.save(source: source, content: content);

    final items = (await library.listLibrary(const LibraryQuery())).items;
    expect(items, hasLength(1));
    expect(items.single.title, '来自发现页的书');
    expect(items.single.author, '测试作者');
    expect(items.single.coverUrl, Uri.parse('https://cdn.example.com/covers/opaque.jpg'));
    expect(items.single.sourceName, '测试数据源');
    expect(items.single.source?.remoteContentId, content.id);
    expect(items.single.description, '完整简介');
    expect(items.single.language, 'zh-CN');
    expect(items.single.accessCode, 'free');
    expect(items.single.chapterCount, 999);
    expect(items.single.categories, <String>['都市小说']);
    expect(items.single.tags, <String>['NPC']);
    expect(items.single.attributes.single.key, 'heat');
    expect(items.single.attributes.single.value, '565.2万');
    expect(items.single.latestChapterId, 'chapter-999');
  });

  test('reports a committed shelf mutation without awaiting reconciliation', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-discovery-save-refresh-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final events = <String>[];
    final saver = ContentLibraryDiscoveryBookshelfSaver(
      library,
      onMutationStarted: (mutation) => events.add('start:${mutation.id}'),
      onMutationCommitted: (mutation, item) => events.add('commit:${item.id.value}'),
    );

    await saver.save(source: _source, content: _content);

    expect(events, hasLength(2));
    expect(events.first, 'start:${_source.id}:${_content.id}');
    expect(events.last, startsWith('commit:'));
  });

  test('saves audio and video source items with their independent shelf kinds', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-discovery-media-save-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final saver = ContentLibraryDiscoveryBookshelfSaver(library);

    for (final contentKind in <PluginContentKind>[PluginContentKind.audio, PluginContentKind.video]) {
      await saver.save(
        source: PluginSourceDescriptor(
          id: 'org.example.${contentKind.name}',
          displayName: '媒体测试源',
          pluginVersion: '1.0.0',
          contentKinds: <PluginContentKind>[contentKind],
        ),
        content: PluginContentSummary(
          id: '${contentKind.name}-content',
          title: '${contentKind.name} 内容',
          contentKind: contentKind,
          author: null,
          url: null,
          coverUrl: null,
          description: null,
          language: null,
          status: PluginContentStatus.unknown,
          access: PluginAccessKind.free,
          wordCount: null,
          chapterCount: 1,
          publishedAt: null,
          updatedAt: null,
          latestChapter: null,
          categories: const <String>[],
          tags: const <String>[],
          attributes: const <PluginContentAttribute>[],
        ),
      );
    }

    final kinds = (await library.listLibrary(const LibraryQuery())).items.map((item) => item.kind).toSet();
    expect(kinds, containsAll(<ContentKind>{ContentKind.audio, ContentKind.video}));
  });

  test('repairs metadata when an existing source item is saved again', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-discovery-save-repair-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });

    final first = await library.bookshelf.addFromSource(
      const BookshelfAddRequest(
        title: '旧书名',
        author: '旧作者',
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '2.4.0',
        remoteContentId: 'repair-id',
      ),
    );
    final repaired = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: '新书名',
        author: '新作者',
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '2.4.0',
        remoteContentId: 'repair-id',
        coverUrl: Uri.parse('https://cdn.example.com/covers/repair.jpg'),
        sourceName: '测试数据源',
      ),
    );

    expect(repaired.id.value, first.id.value);
    expect(repaired.title, '新书名');
    expect(repaired.coverUrl, Uri.parse('https://cdn.example.com/covers/repair.jpg'));
    expect(repaired.sourceName, '测试数据源');
  });
}

final PluginSourceDescriptor _source = PluginSourceDescriptor(
  id: 'org.example.source',
  displayName: '测试数据源',
  pluginVersion: '2.4.0',
  contentKinds: <PluginContentKind>[PluginContentKind.novel],
);

final PluginContentSummary _content = PluginContentSummary(
  id: 'refresh-test-content-id',
  title: '刷新测试书',
  contentKind: PluginContentKind.novel,
  author: '测试作者',
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: PluginContentStatus.unknown,
  access: PluginAccessKind.unknown,
  wordCount: null,
  chapterCount: null,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);
