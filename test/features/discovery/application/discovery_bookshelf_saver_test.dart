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
    final saver = ContentLibraryDiscoveryBookshelfSaver(library);

    await saver.save(source: source, content: content);
    await saver.save(source: source, content: content);

    final items = (await library.listLibrary(const LibraryQuery())).items;
    expect(items, hasLength(1));
    expect(items.single.title, '来自发现页的书');
    expect(items.single.author, '测试作者');
  });
}
