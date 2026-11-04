import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import '../../../core/settings/settings_testkit.dart';
import 'package:mg_read/features/library/presentation/reading_history_page.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('history opens video and audio through their hosts and text through the reader', (tester) async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    final opened = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings), libraryOverviewLoaderProvider.overrideWithValue(_HistoryLoader())],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ReadingHistoryPage(
            onBackRequested: () {},
            onReaderRequested: (id) => opened.add('reader:$id'),
            onVideoEpisodeRequested: ({required detail, required firstCatalogPage, required chapter, libraryItemId}) async {
              opened.add('video:$libraryItemId');
            },
            onAudioChapterRequested:
                ({required detail, required firstCatalogPage, required chapter, required pluginVersion, libraryItemId}) async {
                  opened.add('audio:$libraryItemId');
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final kind in ['video', 'audio', 'novel', 'manga']) {
      final row = find.text('历史$kind');
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
    }
    expect(opened, ['video:video', 'audio:audio', 'reader:novel', 'reader:manga']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the settings secondary-page chrome without bottom navigation', (WidgetTester tester) async {
    var backCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ReadingHistoryPage(onBackRequested: () => backCount += 1, onReaderRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('观看与阅读记录'), findsOneWidget);
    expect(find.text('暂无观看与阅读记录'), findsOneWidget);
    expect(find.byType(AppBottomNavigation), findsNothing);

    await tester.tap(find.byKey(const Key('reading-history-back')));
    expect(backCount, 1);
  });
}

final class _HistoryLoader implements LibraryOverviewLoader {
  @override
  Future<LibraryOverview> load({LibraryVisibility visibility = LibraryVisibility.normal}) async => LibraryOverview(
    items: [
      for (final kind in ContentKind.values)
        LibraryItemSummary(
          id: kind.name,
          title: '历史${kind.name}',
          contentKind: kind,
          readingProgress: kind == ContentKind.novel || kind == ContentKind.manga ? .5 : null,
          lastReadAtUtc: DateTime.utc(2026, 11, 4),
          coverPluginId: 'test',
          coverPluginVersion: '1',
          coverRemoteContentId: kind.name,
        ),
    ],
  );
}
