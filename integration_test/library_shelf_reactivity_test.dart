import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/data/content_library_book_remover.dart';
import 'package:mg_read/features/library/data/content_library_book_visibility_changer.dart';
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shelf mutations are immediate and remain durable on Android', (WidgetTester tester) async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}${Platform.pathSeparator}integration-shelf-reactivity-${DateTime.now().microsecondsSinceEpoch}');
    await root.create(recursive: true);
    final library = await ContentLibrary.open(dataRoot: root);
    var resourcesClosed = false;
    late final ProviderContainer container;
    final saver = ContentLibraryDiscoveryBookshelfSaver(
      library,
      onMutationStarted: (mutation) {
        container
            .read(libraryPageControllerProvider.notifier)
            .beginAddition(
              mutationId: mutation.id,
              provisionalItem: LibraryItemSummary(
                id: 'pending-shelf:${mutation.id}',
                title: mutation.request.title,
                author: mutation.request.author,
                coverUrl: mutation.request.coverUrl,
                sourceName: mutation.request.sourceName,
              ),
            );
      },
      onMutationCommitted: (mutation, item) {
        container
            .read(libraryPageControllerProvider.notifier)
            .commitAddition(
              mutationId: mutation.id,
              durableItem: LibraryItemSummary(
                id: item.id.value,
                title: item.title,
                author: item.author,
                coverUrl: item.coverUrl,
                sourceName: item.sourceName,
              ),
            );
      },
      onMutationFailed: (mutation) {
        container.read(libraryPageControllerProvider.notifier).rollbackAddition(mutation.id);
      },
    );
    container = ProviderContainer(
      overrides: [
        libraryOverviewLoaderProvider.overrideWithValue(ContentLibraryOverviewLoader(library)),
        libraryBookRemoverProvider.overrideWithValue(ContentLibraryBookRemover(library)),
        libraryBookVisibilityChangerProvider.overrideWithValue(ContentLibraryBookVisibilityChanger(library)),
        discoveryBookshelfSaverProvider.overrideWithValue(saver),
      ],
    );
    addTearDown(() async {
      if (!resourcesClosed) {
        container.dispose();
        await library.close();
      }
      if (await root.exists()) await root.delete(recursive: true);
    });

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MgReadApp()));
    await tester.pumpAndSettle();
    expect(find.text('Android 即时书架'), findsNothing);

    final save = saver.save(
      source: _source,
      detail: PluginContentDetail(
        pluginId: _source.id,
        sourceName: _source.displayName,
        summary: _content,
        aliases: const <String>[],
        catalogUrl: _content.url,
      ),
    );
    await tester.pump();
    expect(find.text('Android 即时书架'), findsWidgets);
    await save;
    await tester.pumpAndSettle();
    expect((await library.listLibrary(const LibraryQuery())).items, hasLength(1));

    await tester.drag(find.byType(LibraryBookListItem).first, const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐私'));
    await tester.pumpAndSettle();
    expect(find.text('Android 即时书架'), findsNothing);
    expect((await library.listLibrary(const LibraryQuery(visibility: LibraryVisibility.private))).items, hasLength(1));

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐私书架'));
    await tester.pumpAndSettle();
    expect(find.text('Android 即时书架'), findsWidgets);

    await tester.drag(find.byType(LibraryBookListItem).first, const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消隐私'));
    await tester.pumpAndSettle();
    expect(find.text('暂无隐私书籍'), findsOneWidget);
    expect((await library.listLibrary(const LibraryQuery(visibility: LibraryVisibility.normal))).items, hasLength(1));

    await tester.tap(find.byKey(const Key('private-library-back')));
    await tester.pumpAndSettle();
    expect(find.text('Android 即时书架'), findsWidgets);

    await tester.drag(find.byType(LibraryBookListItem).first, const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    expect(find.text('Android 即时书架'), findsNothing);
    await tester.pumpAndSettle();
    expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('library_shelf_reactivity_light');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    await library.close();
    resourcesClosed = true;
    final reopened = await ContentLibrary.open(dataRoot: root);
    addTearDown(reopened.close);
    expect((await reopened.listLibrary(const LibraryQuery())).items, isEmpty);
  });
}

final PluginSourceDescriptor _source = PluginSourceDescriptor(
  id: 'org.mgread.integration.shelf',
  displayName: '集成测试数据源',
  pluginVersion: '1.0.0',
  contentKinds: const <PluginContentKind>[PluginContentKind.novel],
);

final PluginContentSummary _content = PluginContentSummary(
  id: 'android-shelf-book',
  title: 'Android 即时书架',
  contentKind: PluginContentKind.novel,
  author: '集成测试',
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
