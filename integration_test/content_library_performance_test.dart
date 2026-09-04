/// Profile evidence for the relational Content Library hot paths.
///
/// This benchmark records p50/p95/p99 at the four required catalog sizes. It
/// owns no regression gate because device-specific reader-frame latency is
/// measured separately by reader_first_content_performance_test.dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/core/content_library/content_library.dart';

const _warmups = int.fromEnvironment('MG_READ_CATALOG_PROFILE_WARMUPS', defaultValue: 2);
const _measurements = int.fromEnvironment('MG_READ_CATALOG_PROFILE_MEASUREMENTS', defaultValue: 10);
const _sizes = <int>[100, 600, 5000, 20000];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('catalog append and read Profile distributions', (_) async {
    final root = await Directory.systemTemp.createTemp('mg-read-catalog-profile-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });

    final scenarios = <String, Object?>{};
    for (final size in _sizes) {
      scenarios['chapters-$size'] = await _measureSize(library, size);
    }
    final report = <String, Object?>{
      'schemaVersion': 2,
      'metric': 'relationalContentLibraryCatalog',
      'platform': Platform.operatingSystem,
      'buildMode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
      'warmups': _warmups,
      'measurements': _measurements,
      'scenarios': scenarios,
    };
    binding.reportData = report;
    // flutter test does not write integration reportData to an artifact. Keep
    // one machine-readable line for local evidence and CI log extraction.
    // ignore: avoid_print
    print('MG_READ_CATALOG_PROFILE ${jsonEncode(report)}');
  });
}

Future<Map<String, Object?>> _measureSize(ContentLibrary library, int size) async {
  final chapters = List<SourceNovelCatalogChapter>.generate(
    size,
    (index) => SourceNovelCatalogChapter(remoteIdentity: 'chapter-$index', title: '章节 ${index + 1}', index: index, wordCount: 800 + index),
    growable: false,
  );
  final firstSyncSamples = <int>[];
  LibraryItem? measuredItem;
  for (var sample = 0; sample < _warmups + _measurements; sample++) {
    final item = await library.addLibraryItem(
      BookshelfAddRequest(
        title: '$size 章性能样本 $sample',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'org.mgread.profile.fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'catalog-$size-$sample',
      ),
    );
    final stopwatch = Stopwatch()..start();
    expect(await library.syncNovelCatalog(itemId: item.id, chapters: chapters), size);
    stopwatch.stop();
    if (sample >= _warmups) firstSyncSamples.add(stopwatch.elapsedMicroseconds);
    measuredItem = item;
  }

  final item = measuredItem!;
  final session = (await library.openNovelReaderSession(item.id))!;
  final idempotent = await _measure(() async {
    expect(await library.syncNovelCatalog(itemId: item.id, chapters: chapters), size);
  });
  final firstPage = await _measure(() async {
    final page = await session.page(limit: 100);
    expect(page.items, hasLength(size.clamp(0, 100)));
  });
  final fullCatalog = await _measure(() async {
    String? cursor;
    var count = 0;
    var queries = 0;
    do {
      final page = await session.page(after: cursor, limit: 500);
      count += page.items.length;
      queries++;
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(count, size);
    expect(queries, (size / 500).ceil());
  });
  final target = await _measure(() async {
    final entry = await session.itemAtIndex(size ~/ 2);
    expect(entry?.index, size ~/ 2);
  });

  return <String, Object?>{
    'firstSync': _distribution(firstSyncSamples),
    'idempotentSync': idempotent,
    'first100': firstPage,
    'fullPagination500': fullCatalog,
    'targetByPosition': target,
  };
}

Future<Map<String, int>> _measure(Future<void> Function() operation) async {
  final samples = <int>[];
  for (var index = 0; index < _warmups + _measurements; index++) {
    final stopwatch = Stopwatch()..start();
    await operation();
    stopwatch.stop();
    if (index >= _warmups) samples.add(stopwatch.elapsedMicroseconds);
  }
  return _distribution(samples);
}

Map<String, int> _distribution(List<int> samples) {
  final sorted = List<int>.of(samples)..sort();
  int percentile(double fraction) => sorted[((sorted.length - 1) * fraction).ceil()];
  return <String, int>{
    'sampleCount': sorted.length,
    'p50Micros': percentile(.50),
    'p95Micros': percentile(.95),
    'p99Micros': percentile(.99),
  };
}
