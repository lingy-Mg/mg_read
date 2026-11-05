/// TV detail layout and remote action coverage without source/network IO.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import '../../../support/tv_media_test_fixture.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  for (final grouped in [true, false]) {
    testWidgets('expanding a long catalog (grouped=$grouped) focuses the first new episode', (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 540));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final group = PluginMediaGroup(
        id: 'long',
        title: '长剧',
        order: 0,
        episodes: [
          for (var i = 0; i < 60; i++)
            PluginChapterSummary(
              id: 'ep-$i',
              title: '第${i + 1}集',
              order: i,
              url: null,
              volumeTitle: null,
              wordCount: null,
              updatedAt: null,
              isLocked: false,
              attributes: const [],
            ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTvTheme(AppTheme.dark()),
          builder: (_, child) => TvModeScope(
            enabled: true,
            onChanged: (_) {},
            child: TvRemoteShortcuts(child: child!),
          ),
          home: TvDetailFixtureEntry(
            catalog: PluginChaptersResult(
              pluginId: 'tv-fixture',
              sourceName: '影视测试源',
              items: group.episodes,
              groups: grouped ? [group] : const [],
            ),
            onPlay: ({required detail, required firstCatalogPage, required chapter}) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final moreKey = Key(grouped ? 'source-detail-load-more-group-episodes' : 'source-detail-load-more-chapters');
      final groupId = grouped ? 'long' : 'default';
      for (final id in ['ep-24', 'ep-48']) {
        final more = find.byKey(moreKey);
        await tester.ensureVisible(more);
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.descendant(of: more, matching: find.byType(Text)))).requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        final newEpisode = find.byKey(ValueKey('source-detail-episode-$groupId-$id'));
        expect(newEpisode.hitTestable(), findsOneWidget);
        expect(
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key,
          ValueKey('source-detail-episode-$groupId-$id'),
        );
      }
      expect(find.byKey(moreKey), findsNothing);
    });
  }

  testWidgets('TV favorite removal can be cancelled and confirmed with remote buttons', (tester) async {
    var removed = 0;
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTvTheme(AppTheme.dark()),
        builder: (_, child) => TvModeScope(
          enabled: true,
          onChanged: (_) {},
          child: TvRemoteShortcuts(child: child!),
        ),
        home: TvDetailFixtureEntry(
          onPlay: ({required detail, required firstCatalogPage, required chapter}) async {},
          onSave: (_, _) async {},
          onRemove: () async {
            removed++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('加入收藏'))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('移出收藏'), findsOneWidget);
    // Disabled-during-save controls may return focus to the scope. Restore the
    // known action to exercise the confirmation's own directional traversal.
    final label = find.text('移出收藏');
    Focus.of(tester.element(label)).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('删除书籍'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(removed, 0);
    Focus.of(tester.element(find.text('移出收藏'))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(removed, 1);
    expect(find.text('加入收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final size in [const Size(960, 540), const Size(640, 360)]) {
    testWidgets('TV video detail offers compact viewing actions at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? episode;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTvTheme(AppTheme.dark()),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(size.width == 640 ? 1.6 : 1)),
            child: TvModeScope(
              enabled: true,
              onChanged: (_) {},
              child: TvRemoteShortcuts(child: child!),
            ),
          ),
          home: TvDetailFixtureEntry(
            onPlay: ({required detail, required firstCatalogPage, required chapter}) async => episode = chapter.id,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-video-detail-summary')), findsOneWidget);
      expect(find.text('字数'), findsNothing);
      expect(find.textContaining('作者未知'), findsNothing);
      expect(find.text('加入收藏'), findsOneWidget);
      expect(find.byKey(const Key('source-detail-start-reading')).hitTestable(), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key,
        const Key('source-detail-start-reading'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(episode, 'a-0');
      if (size.width == 960) {
        await expectLater(find.byKey(const Key('source-content-detail-sheet')), matchesGoldenFile('goldens/tv_video_detail.png'));
      }
      // Move from the summary to the independent catalog pane, then down to an episode.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      for (var i = 0; i < 12; i++) {
        final focused = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>();
        if (focused?.key.toString().contains('source-detail-episode-') == true) break;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      // At short widths the episode grid has two columns; assert selection of
      // an actual focused episode rather than relying on a fixed press count.
      final focused = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>();
      expect(focused?.key.toString(), contains('source-detail-episode-'));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(episode, startsWith('a-'));
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-video-detail-summary')), findsNothing);
    });
  }
}
