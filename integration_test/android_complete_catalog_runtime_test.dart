import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android Runtime returns and reads the complete 733 chapter catalog',
    (tester) async {
      await tester.pump();
      final runtime = PluginRuntime();
      addTearDown(runtime.debugDispose);
      await runtime.invoke(
        const PluginInstallationSizeInvocation(
          pluginId: 'org.mgread.aisishuwu',
          scope: PluginInstallationSizeScope.archive,
        ),
      );
      final plugins = await runtime.invoke(const InstalledPluginsInvocation());
      final aisishuwu = plugins.singleWhere(
        (plugin) => plugin.id == 'org.mgread.aisishuwu',
      );
      expect(aisishuwu.status, 'active');
      expect(aisishuwu.activeVersion, '0.2.7');

      final detail = await runtime.invoke(
        const SourceDetailInvocation(
          pluginId: 'org.mgread.aisishuwu',
          id: 'novel:52801',
        ),
      );
      expect(detail.summary.chapterCount, 733);
      final chapters = await runtime.invoke(
        const SourceChaptersInvocation(
          pluginId: 'org.mgread.aisishuwu',
          id: 'novel:52801',
        ),
      );
      expect(chapters.items, hasLength(733));
      expect(
        chapters.items.map((chapter) => chapter.id).toSet(),
        hasLength(733),
      );
      expect(
        chapters.items.map((chapter) => chapter.order),
        orderedEquals(List<int>.generate(733, (index) => index)),
      );

      final libraryRoot = await Directory.systemTemp.createTemp(
        'mg-read-android-complete-catalog-',
      );
      final library = await ContentLibrary.open(dataRoot: libraryRoot);
      addTearDown(() async {
        await library.close();
        await libraryRoot.delete(recursive: true);
      });
      final shelfItem = await library.bookshelf.addFromSource(
        BookshelfAddRequest(
          title: detail.summary.title,
          author: detail.summary.author,
          kind: ContentKind.novel,
          pluginId: aisishuwu.id,
          pluginVersion: aisishuwu.activeVersion!,
          remoteContentId: detail.summary.id,
        ),
      );
      final gateway = _RuntimeSourceGateway(runtime);
      final prefetcher = ContentLibrarySourcePrefetcher(library, gateway);
      final reader = ContentLibrarySourceTextReader(
        library,
        gateway,
        prefetcher,
      );

      prefetcher.start(shelfItem);
      final launch = await reader.launch(shelfItem.id.value);

      expect(await library.listAllCatalog(shelfItem.id), hasLength(733));
      final lastChapter = await launch.dataSource.loadChapterAtIndex(
        launch.bookId,
        732,
      );
      final lastContent = await launch.dataSource.loadChapterContent(
        launch.bookId,
        lastChapter.id,
      );
      expect(lastContent.paragraphs, isNotEmpty);
    },
  );
}

final class _RuntimeSourceGateway implements SourceContentGateway {
  const _RuntimeSourceGateway(this._runtime);

  final PluginRuntime _runtime;

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) => _runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) => _runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) => _runtime.invoke(
    SourceContentInvocation(pluginId: pluginId, id: id, chapterId: chapterId),
  );

  @override
  Future<List<PluginSourceDescriptor>> listSources() =>
      throw UnsupportedError('Not used by the Android reader flow.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by the Android reader flow.');

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by the Android reader flow.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by the Android reader flow.');
}
