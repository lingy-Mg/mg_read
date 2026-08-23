import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

import 'fixtures/alice_book_house_detail_fixture.dart';

void main() {
  testWidgets(
    'detail forwards one typed shelf save while the request is active',
    (tester) async {
      var saveCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: _DetailHost(onAddToShelf: (_) async => saveCount++),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
      await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
      await tester.pumpAndSettle();

      expect(saveCount, 1);
      expect(find.text('已加入书架。'), findsOneWidget);
    },
  );

  testWidgets('detail reports a shelf save failure', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _DetailHost(
          onAddToShelf: (_) => Future<void>.error(StateError('save failed')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法加入书架，请稍后重试。'), findsOneWidget);
  });

  testWidgets('shelf detail adapts the add action to an existing shelf item', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: _ShelfDetailHost()),
    );
    await tester.pumpAndSettle();

    expect(find.text('已在书架'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.pumpAndSettle();
    expect(find.text('此书已在书架中。'), findsOneWidget);
  });
}

class _DetailHost extends StatefulWidget {
  const _DetailHost({required this.onAddToShelf});

  final SourceShelfSaveRequested onAddToShelf;

  @override
  State<_DetailHost> createState() => _DetailHostState();
}

class _DetailHostState extends State<_DetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _FixtureGateway(),
          pluginId: AliceBookHouseDetailFixture.pluginId,
          id: AliceBookHouseDetailFixture.bookId,
          onAddToShelf: widget.onAddToShelf,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final class _FixtureGateway implements SourceContentGateway {
  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => AliceBookHouseDetailFixture.detail;

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) async => AliceBookHouseDetailFixture.firstCatalogPage;

  @override
  Future<List<PluginSourceDescriptor>> listSources() =>
      throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) => throw UnimplementedError();
}

class _ShelfDetailHost extends StatefulWidget {
  @override
  State<_ShelfDetailHost> createState() => _ShelfDetailHostState();
}

class _ShelfDetailHostState extends State<_ShelfDetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _FixtureGateway(),
          pluginId: AliceBookHouseDetailFixture.pluginId,
          id: AliceBookHouseDetailFixture.bookId,
          shelfState: SourceDetailShelfState.alreadyAdded,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}
