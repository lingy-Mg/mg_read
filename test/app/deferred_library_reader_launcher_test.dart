import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

void main() {
  test('deferred launcher keeps novel and manga sessions typed and supplies the manga cover', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-launcher-');
    final library = await ContentLibrary.open(dataRoot: root);
    final diagnostics = DiagnosticsManager(
      sink: const NoopDiagnosticEventSink(),
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
    );
    addTearDown(() async {
      await diagnostics.close();
      await library.close();
      await root.delete(recursive: true);
    });
    final novel = await library.bookshelf.addFromSource(
      const BookshelfAddRequest(
        title: '测试小说',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'fixture',
        pluginVersion: '1',
        remoteContentId: 'novel',
      ),
    );
    final mangaCoverUrl = Uri.parse('https://fixture.example/manga-cover.png');
    final manga = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: '测试漫画',
        author: null,
        kind: ContentKind.manga,
        pluginId: 'fixture',
        pluginVersion: '1',
        remoteContentId: 'manga',
        coverUrl: mangaCoverUrl,
      ),
    );
    const mangaCoverBytes = <int>[1, 2, 3, 4];
    await library.covers.save(
      key: CoverKey(pluginId: 'fixture', pluginVersion: '1', remoteContentId: 'manga', coverUrl: mangaCoverUrl),
      bytes: mangaCoverBytes,
      mimeType: 'image/png',
    );
    final launcher = DeferredLibraryReaderLauncher(() async => library, const _Gateway(), diagnostics);

    final novelRequest = await launcher.launch(novel.id.value);
    final mangaRequest = await launcher.launch(manga.id.value);

    expect(novelRequest, isA<NovelReaderLaunchRequest>());
    expect(mangaRequest, isA<ComicReaderLaunchRequest>());
    expect(mangaRequest.entryCoverBytes, mangaCoverBytes);
    expect(await launcher.warmLocal(novel.id.value), isA<NovelReaderLaunchRequest>());
    expect(await launcher.warmLocal(manga.id.value), isNull);
  });
}

final class _Gateway implements SourceContentGateway {
  const _Gateway();

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: 'fixture',
    items: <PluginChapterSummary>[
      PluginChapterSummary(
        id: 'chapter-1',
        title: '第一章',
        order: 0,
        url: null,
        volumeTitle: null,
        wordCount: 4,
        updatedAt: null,
        isLocked: false,
        attributes: <PluginContentAttribute>[],
      ),
    ],
  );

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async =>
      PluginChapterContent(
        pluginId: pluginId,
        sourceName: 'fixture',
        contentKind: PluginContentKind.novel,
        chapterId: chapterId,
        title: '第一章',
        updatedAt: null,
        text: '测试正文',
        pages: const <PluginMangaPage>[],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
