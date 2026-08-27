/// Profile evidence for metadata JSON preparation and real small writes.
///
/// This benchmark records distributions without imposing a fabricated
/// millisecond gate. Run it separately on Windows and an authorized Android
/// emulator; unit tests own correctness and this file owns platform evidence.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';

const _warmups = int.fromEnvironment('MG_READ_PERSISTENCE_PROFILE_WARMUPS', defaultValue: 3);
const _measurements = int.fromEnvironment('MG_READ_PERSISTENCE_PROFILE_MEASUREMENTS', defaultValue: 20);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('metadata JSON write and decode Profile distributions', (_) async {
    final root = await Directory.systemTemp.createTemp('mg-read-persistence-profile-');
    final library = await ContentLibrary.open(dataRoot: Directory('${root.path}${Platform.pathSeparator}library'));
    final settingsRegistry = AppSettingKeys.registry;
    final settingsRecords = await PersistenceRecordStore.open(
      dataRoot: Directory('${root.path}${Platform.pathSeparator}settings'),
      registry: RecordDocumentRegistry(settingsRecordDocumentCodecs(settingsRegistry, scopeKind: 'profile-settings')),
    );
    final settings = PersistentSettingsStore(
      records: settingsRecords,
      scope: const ScopeKey(kind: 'profile-settings', id: 'default'),
      registry: settingsRegistry,
    );
    addTearDown(() async {
      await settingsRecords.close();
      await library.close();
      await root.delete(recursive: true);
    });

    final item = await library.bookshelf.addFromSource(
      const BookshelfAddRequest(
        title: 'JSON Profile Book',
        author: 'Profile',
        kind: ContentKind.novel,
        pluginId: 'org.mgread.profile.fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'json-profile-book',
      ),
    );
    var settingsDocument = SettingsDocument(
      id: AppSettingKeys.appearanceDocument.id,
      kind: AppSettingKeys.appearanceDocument.kind,
      values: const <String, Object?>{'appearance.themeMode': 'system'},
    );
    final codecRegistry = RecordDocumentRegistry(contentLibraryRecordDocumentCodecs);
    final progressCodec = codecRegistry.require('content_library_reading_progress', 'content_library');
    final smallPayload = jsonEncode(_progressDocument(0));
    final largePayload = jsonEncode(<String, Object?>{..._progressDocument(0), 'extension': 'x' * (5 * 1024)});

    final inlinePrepared = await progressCodec.prepareCurrent(_progressDocument(0));
    expect(inlinePrepared.executionIsolateId, Isolate.current.hashCode);
    final backgroundPrepared = await progressCodec.prepareCurrent(<String, Object?>{
      ..._progressDocument(0),
      'extension': List<int>.generate(65, (index) => index),
    });
    expect(backgroundPrepared.executionIsolateId, isNot(Isolate.current.hashCode));
    final inlineDecoded = await progressCodec.decodeAndUpgrade(version: 1, payloadJson: smallPayload);
    expect(inlineDecoded.executionIsolateId, Isolate.current.hashCode);
    final backgroundDecoded = await progressCodec.decodeAndUpgrade(version: 1, payloadJson: largePayload);
    expect(backgroundDecoded.executionIsolateId, isNot(Isolate.current.hashCode));
    expect(backgroundDecoded.document['chapterId'], 'chapter-0');

    final results = <String, Object?>{
      'jsonPrepareInline': await _measure((index) async {
        await progressCodec.prepareCurrent(_progressDocument(index));
      }),
      'jsonPrepareWorkerFallback': await _measure((index) async {
        await progressCodec.prepareCurrent(<String, Object?>{
          ..._progressDocument(index),
          'extension': List<int>.generate(65, (value) => value),
        });
      }),
      'jsonDecodeInline': await _measure((_) async {
        await progressCodec.decodeAndUpgrade(version: 1, payloadJson: smallPayload);
      }),
      'jsonDecodeWorkerFallback': await _measure((_) async {
        await progressCodec.decodeAndUpgrade(version: 1, payloadJson: largePayload);
      }),
      'readingProgressRealWrite': await _measure((index) async {
        await library.readingProgress.save(
          LibraryReadingProgress(
            itemId: item.id,
            chapterId: 'chapter-$index',
            paragraphId: 'paragraph-$index',
            characterOffset: index,
            chapterIndex: index,
            chapterFraction: 0.25,
            bookFraction: 0.5,
            updatedAtUtc: DateTime.utc(2026, 8, 27).add(Duration(seconds: index)),
            totalReadingSeconds: index,
          ),
        );
      }),
      'settingsCasRealWrite': await _measure((index) async {
        settingsDocument = (await settings.writeAll(<SettingsDocument>[
          SettingsDocument(
            id: settingsDocument.id,
            kind: settingsDocument.kind,
            revision: settingsDocument.revision,
            values: <String, Object?>{'appearance.themeMode': index.isEven ? 'light' : 'dark'},
          ),
        ])).single;
      }),
      'catalogBatchPrepare': await _measure((index) async {
        await codecRegistry.prepareCurrentMany(
          documents: List.generate(
            128,
            (entryIndex) => (
              recordKind: 'content_catalog_entry',
              scopeKind: 'content_library',
              document: <String, Object?>{'title': 'chapter-$index-$entryIndex'},
            ),
            growable: false,
          ),
        );
      }),
    };

    binding.reportData = <String, Object?>{
      'schemaVersion': 1,
      'metric': 'metadataJsonPreparationAndWrite',
      'platform': Platform.operatingSystem,
      'buildMode': 'profile',
      'warmups': _warmups,
      'measurements': _measurements,
      'scenarios': results,
    };
  });
}

Map<String, Object?> _progressDocument(int index) => <String, Object?>{
  'chapterId': 'chapter-$index',
  'paragraphId': 'paragraph-$index',
  'characterOffset': index,
  'chapterIndex': index,
  'chapterFraction': 0.25,
  'bookFraction': 0.5,
  'updatedAtUtc': '2026-08-27T00:00:00.000Z',
  'totalReadingSeconds': index,
};

Future<Map<String, Object?>> _measure(Future<void> Function(int index) operation) async {
  final samples = <int>[];
  for (var index = 0; index < _warmups + _measurements; index++) {
    final stopwatch = Stopwatch()..start();
    await operation(index);
    stopwatch.stop();
    if (index >= _warmups) samples.add(stopwatch.elapsedMicroseconds);
  }
  samples.sort();
  final total = samples.fold<int>(0, (sum, value) => sum + value);
  return <String, Object?>{
    'count': samples.length,
    'minMicros': samples.first,
    'p50Micros': _percentile(samples, 0.50),
    'p95Micros': _percentile(samples, 0.95),
    'maxMicros': samples.last,
    'meanMicros': total / samples.length,
  };
}

int _percentile(List<int> sorted, double percentile) {
  final index = ((sorted.length - 1) * percentile).ceil();
  return sorted[index];
}
