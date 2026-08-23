import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

void main() {
  test('saves a typed discovery item in the app-owned bookshelf', () async {
    final root = await Directory.systemTemp.createTemp(
      'mg-read-discovery-save-',
    );
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final source = PluginSourceDescriptor(
      id: 'org.example.source',
      displayName: '测试书源',
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
    final saver = ContentLibraryDiscoveryBookshelfSaver(library);

    await saver.save(source: source, content: content);
    await saver.save(source: source, content: content);

    final items = (await library.listLibrary(const LibraryQuery())).items;
    expect(items, hasLength(1));
    expect(items.single.title, '来自发现页的书');
    expect(items.single.author, '测试作者');
    expect(
      items.single.coverUrl,
      Uri.parse('https://cdn.example.com/covers/opaque.jpg'),
    );
    expect(items.single.sourceName, '测试书源');
    expect(items.single.source?.remoteContentId, content.id);
  });

  test('reports a committed shelf mutation without awaiting reconciliation', () async {
    final root = await Directory.systemTemp.createTemp(
      'mg-read-discovery-save-refresh-',
    );
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final events = <String>[];
    final saver = ContentLibraryDiscoveryBookshelfSaver(
      library,
      onMutationStarted: (mutation) => events.add('start:${mutation.id}'),
      onMutationCommitted: (mutation, item) =>
          events.add('commit:${item.id.value}'),
    );

    await saver.save(source: _source, content: _content);

    expect(events, hasLength(2));
    expect(events.first, 'start:${_source.id}:${_content.id}');
    expect(events.last, startsWith('commit:'));
  });

  test(
    'repairs metadata when an existing source item is saved again',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-discovery-save-repair-',
      );
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
          sourceName: '测试书源',
        ),
      );

      expect(repaired.id.value, first.id.value);
      expect(repaired.title, '新书名');
      expect(
        repaired.coverUrl,
        Uri.parse('https://cdn.example.com/covers/repair.jpg'),
      );
      expect(repaired.sourceName, '测试书源');
    },
  );
}

final PluginSourceDescriptor _source = PluginSourceDescriptor(
  id: 'org.example.source',
  displayName: '测试书源',
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
