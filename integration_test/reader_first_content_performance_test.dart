import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';

const _anchorText = 'PERF_ANCHOR 首段正文已经实际呈现';
const _warmups = int.fromEnvironment(
  'MG_READ_PROFILE_WARMUPS',
  defaultValue: 5,
);
const _measurements = int.fromEnvironment(
  'MG_READ_PROFILE_MEASUREMENTS',
  defaultValue: 50,
);
const _hardP95Micros = 100000;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shelf reader first-content Profile distributions', (
    WidgetTester tester,
  ) async {
    final dataRoot = await Directory.systemTemp.createTemp(
      'mg-read-reader-profile-',
    );
    final library = await ContentLibrary.open(dataRoot: dataRoot);
    addTearDown(() async {
      await library.close();
      await dataRoot.delete(recursive: true);
    });
    final gateway = _ProfileSourceGateway();
    await ContentLibraryDiscoveryBookshelfSaver(library).save(
      source: PluginSourceDescriptor(
        id: 'org.mgread.profile.fixture',
        displayName: '性能探针书源',
        pluginVersion: '1.0.0',
        contentKinds: const <PluginContentKind>[PluginContentKind.novel],
      ),
      content: _profileSummary,
    );
    final item = (await library.listLibrary(const LibraryQuery())).items.single;
    final bookId = item.id.value;
    final persistedReader = ContentLibrarySourceTextReader(library, gateway);
    final seedRequest = await persistedReader.launch(bookId);
    await seedRequest.stateStore.saveProgress(
      bookId,
      const ReaderProgress(
        chapterId: 'chapter-1',
        paragraphId: 'chapter-1:paragraph:20',
        characterOffset: 0,
        chapterIndex: 0,
        chapterFraction: 0.25,
        bookFraction: 0.25,
      ),
    );
    expect(gateway.contentRequests, 1);
    gateway.rejectAllRequests = true;
    final launcher = _ProfileReaderLauncher(persistedReader);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryOverviewLoaderProvider.overrideWithValue(
            _PerformanceOverviewLoader(bookId),
          ),
          libraryReaderLauncherProvider.overrideWithValue(launcher),
        ],
        child: ExcludeSemantics(
          excluding: Platform.isWindows,
          child: const MgReadApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryBookListItem).first),
    );
    final coordinator = container.read(
      shelfReaderLaunchCoordinatorProvider.notifier,
    );
    final originalSize = tester.view.physicalSize;
    final originalDpr = tester.view.devicePixelRatio;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final results = <String, Object?>{};
    for (final scenario in _ProfileScenario.values) {
      final samples = <ShelfReaderLaunchSample>[];
      for (
        var iteration = 0;
        iteration < _warmups + _measurements;
        iteration += 1
      ) {
        launcher.scenario = scenario;
        coordinator.clear();
        if (scenario == _ProfileScenario.memoryHit) {
          await coordinator.warm(<String>[bookId]);
        }
        if (scenario == _ProfileScenario.layoutFingerprintInvalidated) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(720 + iteration.toDouble(), 1280);
          await tester.pump();
        } else {
          tester.view.devicePixelRatio = originalDpr;
          tester.view.physicalSize = originalSize;
          await tester.pump();
        }

        final shelfItem = find.byType(LibraryBookListItem).hitTestable().first;
        expect(shelfItem, findsOneWidget);
        await tester.tap(shelfItem);
        await _pumpUntil(
          tester,
          () => find.textContaining(_anchorText).evaluate().isNotEmpty,
        );
        await tester.pump();
        final sample = coordinator.lastCompletedSample;
        expect(sample, isNotNull, reason: '${scenario.name} did not complete');
        if (iteration >= _warmups) samples.add(sample!);

        // Route transitions are outside the measured click-to-content span.
        // Settle, reveal the controls through the stable reader surface key,
        // then choose the one currently hit-testable back action.
        await tester.pumpAndSettle();
        final readerSurface = find
            .byKey(const ValueKey<String>('reader-content-surface'))
            .hitTestable()
            .first;
        expect(readerSurface, findsOneWidget);
        await tester.tap(readerSurface);
        await tester.pump(const Duration(milliseconds: 200));
        final backAction = find
            .byKey(const ValueKey<String>('reader-back-action'))
            .hitTestable()
            .first;
        expect(backAction, findsOneWidget);
        await tester.tap(backAction);
        await _pumpUntil(
          tester,
          () => find
              .byType(LibraryBookListItem)
              .hitTestable()
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
      }
      final distribution = _distribution(samples);
      results[scenario.name] = distribution;
      expect(
        distribution['p95Micros'],
        lessThanOrEqualTo(_hardP95Micros),
        reason: '${scenario.name} P95 exceeded 100ms',
      );
    }

    binding.reportData = <String, Object?>{
      'schemaVersion': 1,
      'metric': 'shelfTapToFirstContentFrame',
      'platform': Platform.operatingSystem,
      'buildMode': 'profile',
      'warmupsPerScenario': _warmups,
      'measurementsPerScenario': _measurements,
      'hardP95Micros': _hardP95Micros,
      'scenarios': results,
    };
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 240; attempt += 1) {
    if (predicate()) return;
    await tester.pump(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for the reader performance state.');
}

Map<String, Object?> _distribution(List<ShelfReaderLaunchSample> samples) {
  int percentile(List<int> values, double fraction) {
    values.sort();
    return values[((values.length - 1) * fraction).ceil()];
  }

  Map<String, int> phasePercentiles(
    Duration Function(ShelfReaderLaunchSample sample) select,
  ) {
    final values = samples
        .map((sample) => select(sample).inMicroseconds)
        .toList();
    return <String, int>{
      'p50Micros': percentile(List<int>.of(values), 0.50),
      'p95Micros': percentile(List<int>.of(values), 0.95),
      'p99Micros': percentile(List<int>.of(values), 0.99),
    };
  }

  return <String, Object?>{
    'sampleCount': samples.length,
    ...phasePercentiles((sample) => sample.total),
    'preparation': phasePercentiles((sample) => sample.preparation),
    'firstPageLayout': phasePercentiles((sample) => sample.firstPageLayout),
    'pathCategories': <String, int>{
      for (final kind in ReaderLaunchPreparationKind.values)
        kind.wireValue: samples
            .where((sample) => sample.preparationKind == kind)
            .length,
    },
    'paginationPreparation': <String, int>{
      for (final kind in ReaderPaginationPreparation.values)
        kind.name: samples
            .where((sample) => sample.paginationPreparation == kind.name)
            .length,
    },
  };
}

enum _ProfileScenario {
  persistentCold,
  memoryHit,
  layoutFingerprintHit,
  layoutFingerprintInvalidated,
}

final class _ProfileReaderLauncher
    implements LibraryReaderLauncher, LocalShelfReaderPrewarmer {
  _ProfileReaderLauncher(this._delegate);

  final ContentLibrarySourceTextReader _delegate;
  _ProfileScenario scenario = _ProfileScenario.persistentCold;
  var _generation = 0;

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId, {
    ReaderObserver? observer,
  }) async =>
      _decorate(await _delegate.launch(libraryItemId, observer: observer));

  @override
  Future<ReaderLaunchRequest?> warmLocal(String libraryItemId) async {
    if (scenario != _ProfileScenario.memoryHit) return null;
    final request = await _delegate.warmLocal(libraryItemId);
    return request == null ? null : _decorate(request);
  }

  ReaderLaunchRequest _decorate(ReaderLaunchRequest request) {
    _generation += 1;
    final version = switch (scenario) {
      _ProfileScenario.layoutFingerprintHit => 'stable-layout-v1',
      _ProfileScenario.layoutFingerprintInvalidated => 'stable-layout-v1',
      _ => 'content-$_generation',
    };
    return ReaderLaunchRequest(
      bookId: request.bookId,
      dataSource: _VersionedProfileDataSource(request.dataSource, version),
      stateStore: request.stateStore,
      observer: request.observer,
      controller: request.controller,
      extensions: request.extensions,
      estimatedWarmBytes: request.estimatedWarmBytes,
      preparationKind: request.preparationKind,
      networkPreparationElapsed: request.networkPreparationElapsed,
    );
  }
}

final class _PerformanceOverviewLoader implements LibraryOverviewLoader {
  const _PerformanceOverviewLoader(this.bookId);

  final String bookId;

  @override
  Future<LibraryOverview> load({Object? visibility}) async => LibraryOverview(
    items: <LibraryItemSummary>[
      LibraryItemSummary(
        id: bookId,
        title: '首屏性能测试书',
        readingProgress: 0.4,
        readingChapterIndex: 0,
        lastReadAtUtc: DateTime.utc(2026, 8, 24),
      ),
    ],
  );
}

final class _VersionedProfileDataSource implements TextReaderDataSource {
  const _VersionedProfileDataSource(this.delegate, this.version);

  final TextReaderDataSource delegate;
  final String version;

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) =>
      delegate.loadBookInfo(bookId);

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) => delegate.loadChapterCatalog(bookId, cursor: cursor, pageSize: pageSize);

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) =>
      delegate.loadChapterAtIndex(bookId, index);

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    final content = await delegate.loadChapterContent(bookId, chapterId);
    return TextChapterContent(
      chapterId: content.chapterId,
      title: content.title,
      contentVersion: version,
      chapterUrl: content.chapterUrl,
      paragraphs: content.paragraphs,
    );
  }
}

final class _ProfileSourceGateway implements SourceContentGateway {
  var rejectAllRequests = false;
  var contentRequests = 0;

  Never _unexpected() => throw StateError(
    'Profile local-hit path attempted to access the source gateway.',
  );

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async {
    if (rejectAllRequests) _unexpected();
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '性能探针书源',
      items: <PluginChapterSummary>[
        PluginChapterSummary(
          id: 'chapter-1',
          title: '第一章',
          order: 0,
          url: null,
          volumeTitle: null,
          wordCount: null,
          updatedAt: null,
          isLocked: false,
          attributes: const <PluginContentAttribute>[],
        ),
      ],
    );
  }

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async {
    if (rejectAllRequests) _unexpected();
    contentRequests += 1;
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '性能探针书源',
      contentKind: PluginContentKind.novel,
      chapterId: chapterId,
      title: '第一章',
      updatedAt: null,
      text: <String>[
        for (var index = 0; index < 80; index += 1)
          index == 20
              ? '$_anchorText。用于验证语义锚点与首帧。'
              : List<String>.filled(4, '第$index段用于构造稳定的本地小说正文和分页测量。').join(),
      ].join('\n\n'),
      pages: const <PluginMangaPage>[],
    );
  }

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => _unexpected();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async => _unexpected();

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => _unexpected();

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) async => _unexpected();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) async => _unexpected();
}

final PluginContentSummary _profileSummary = PluginContentSummary(
  id: 'reader-performance-book',
  title: '首屏性能测试书',
  contentKind: PluginContentKind.novel,
  author: '性能探针',
  url: null,
  coverUrl: null,
  description: null,
  language: 'zh-CN',
  status: PluginContentStatus.ongoing,
  access: PluginAccessKind.free,
  wordCount: null,
  chapterCount: 1,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);
