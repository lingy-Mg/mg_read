/// 导入导出页面的选择与文案回归测试。
///
/// 使用内存协调器验证页面交互，不打开系统文件选择器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/import_export/application/import_export_service.dart';
import 'package:mg_read/features/import_export/presentation/import_export_page.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  testWidgets('discloses packaged-only development export and selects individual projects', (tester) async {
    final coordinator = _FakeCoordinator();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ImportExportPage(onBackRequested: () {}, coordinator: coordinator),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('导入导出'), findsOneWidget);
    expect(find.byKey(const Key('import-export-overview')), findsOneWidget);
    expect(find.textContaining('只导出 artifact，不导出源码'), findsOneWidget);
    await tester.tap(find.byKey(const Key('prepare-export')));
    await tester.pumpAndSettle();

    expect(find.text('选择导出项目'), findsOneWidget);
    expect(find.text('开发数据源'), findsOneWidget);
    expect(find.text('书架书籍'), findsOneWidget);

    await tester.tap(find.byKey(Key('export-shelf-${_shelf.identity}')));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('export-selected')),
      200,
      scrollable: find.descendant(of: find.byKey(const Key('import-export-content')), matching: find.byType(Scrollable)),
    );
    await tester.drag(find.byKey(const Key('import-export-content')), const Offset(0, -80));
    await tester.pump();
    await tester.tap(find.byKey(const Key('export-selected')));
    await tester.pumpAndSettle();

    expect(coordinator.exportedPluginIds, <String>{_plugin.id});
    expect(coordinator.exportedShelfIds, isEmpty);
    expect(find.textContaining('导出完成'), findsOneWidget);
  });

  testWidgets('uses comic reading progress and manga bookmarks in local document summary', (tester) async {
    final coordinator = _FakeCoordinator()..localDocuments = <LanSyncLocalDocumentDescriptor>[_comicDocument];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ImportExportPage(onBackRequested: () {}, coordinator: coordinator),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prepare-export')));
    await tester.pumpAndSettle();

    final summary = find.text('EPUB 原文件 · 1.0 MiB · 含阅读进度 · 2 个书签');
    await tester.ensureVisible(summary);
    expect(summary, findsOneWidget);
  });

  test('capacity failure has explicit local-import user feedback', () {
    expect(importExportFailureMessage(const LanSyncGatewayException(bookshelfCapacityExceededCode), fallback: '导入失败'), '书架已满，请先清理书籍。');
  });
}

const _plugin = LanSyncPluginDescriptor(
  id: 'org.example.dev',
  version: '1.0.1-devsync.1',
  bytes: 5,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  checksum: 'bbbbbbbb',
  transferable: true,
  displayName: '开发数据源',
);

const _shelf = LanSyncShelfItem(
  pluginId: 'org.example.dev',
  pluginVersion: '1.0.0',
  remoteContentId: 'book',
  contentKind: 'novel',
  title: '书架书籍',
);

final class _FakeCoordinator implements ImportExportCoordinator {
  Set<String>? exportedPluginIds;
  Set<String>? exportedShelfIds;
  List<LanSyncLocalDocumentDescriptor> localDocuments = const <LanSyncLocalDocumentDescriptor>[];

  @override
  Future<ImportExportExportPlan> prepareExport() async => ImportExportExportPlan(
    LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[_plugin],
      shelfItems: const <LanSyncShelfItem>[_shelf],
      skippedShelfItems: 0,
      localDocuments: localDocuments,
    ),
  );

  @override
  Future<bool> exportSelection(
    ImportExportExportPlan plan, {
    required Set<String> pluginIds,
    required Set<String> shelfItemIds,
    Set<String> localDocumentIds = const {},
  }) async {
    exportedPluginIds = Set<String>.from(pluginIds);
    exportedShelfIds = Set<String>.from(shelfItemIds);
    return true;
  }

  @override
  Future<ImportExportImportPlan?> pickImport() async => null;

  @override
  Future<LanSyncApplyResult> importSelection(
    ImportExportImportPlan plan, {
    required Set<String> pluginIds,
    required Set<String> shelfItemIds,
    Set<String> localDocumentIds = const {},
    required Map<String, LanSyncConflictChoice> conflictChoices,
  }) async => throw UnimplementedError();
}

final _comicDocument = LanSyncLocalDocumentDescriptor(
  documentId: 'comic-document-identifier',
  rawSha256: 'b' * 64,
  originalBytes: 1024 * 1024,
  format: 'epub',
  title: '本地漫画',
  options: const <String, Object?>{},
  readingKind: LanSyncLocalReadingKind.comic,
  mangaProgress: LanSyncLocalMangaProgress(
    chapterId: 'chapter-1',
    imageId: 'image-2',
    imageFraction: .42,
    chapterIndex: 0,
    bookFraction: .25,
    updatedAtUtc: DateTime.utc(2026, 11, 4),
    readingSeconds: 60,
  ),
  mangaBookmarks: <LanSyncLocalMangaBookmark>[
    LanSyncLocalMangaBookmark(
      id: 'bookmark-1',
      chapterId: 'chapter-1',
      imageId: 'image-1',
      imageFraction: .15,
      createdAtUtc: DateTime.utc(2026, 11, 4),
    ),
    LanSyncLocalMangaBookmark(
      id: 'bookmark-2',
      chapterId: 'chapter-1',
      imageId: 'image-3',
      imageFraction: .7,
      createdAtUtc: DateTime.utc(2026, 11, 4),
    ),
  ],
);
