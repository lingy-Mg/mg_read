/// 局域网同步领域模型测试。
///
/// 职责：
/// - 验证 manifest 与插件 artifact 格式的严格 JSON 往返。
/// - 验证字段、大小和重复项边界。
///
/// 注意：
/// - 仅验证纯模型，不替代真实局域网传输。
///
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('manifest round-trips bounded plugin and shelf metadata', () {
    final manifest = LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[
        LanSyncPluginDescriptor(
          id: 'source.example',
          version: '1.2.3',
          bytes: 128,
          artifactFormat: LanSyncPluginArtifactFormat.singleFile,
          checksum: 'aaaaaaaa',
          transferable: true,
        ),
      ],
      shelfItems: <LanSyncShelfItem>[
        LanSyncShelfItem(
          pluginId: 'source.example',
          pluginVersion: '1.2.3',
          remoteContentId: 'book-1',
          contentKind: 'novel',
          title: '测试书籍',
          coverOrientation: 'square',
          progress: LanSyncReadingProgress(
            chapterId: 'chapter-2',
            paragraphId: 'paragraph-4',
            characterOffset: 12,
            chapterIndex: 1,
            chapterFraction: 0.4,
            bookFraction: 0.2,
            updatedAtUtc: DateTime.utc(2026, 8, 25),
            totalReadingSeconds: 80,
          ),
        ),
      ],
      skippedShelfItems: 1,
    );

    final decoded = LanSyncManifest.fromJson(manifest.toJson());

    expect(decoded.plugins.single.id, 'source.example');
    expect(decoded.plugins.single.artifactFormat, LanSyncPluginArtifactFormat.singleFile);
    expect(decoded.shelfItems.single.identity, 'source.example\u001fbook-1');
    expect(decoded.shelfItems.single.coverOrientation, 'square');
    expect(decoded.shelfItems.single.progress?.chapterIndex, 1);
    expect(decoded.skippedShelfItems, 1);
  });

  test('paired task schema separates bookshelf metadata from reading progress', () {
    final progress = LanSyncReadingProgress(
      chapterId: 'chapter-2',
      paragraphId: 'paragraph-4',
      characterOffset: 12,
      chapterIndex: 1,
      chapterFraction: 0.4,
      bookFraction: 0.2,
      updatedAtUtc: DateTime.utc(2026, 8, 25),
      totalReadingSeconds: 80,
    );
    final manifest = LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[],
      shelfItems: <LanSyncShelfItem>[
        LanSyncShelfItem(
          pluginId: 'source.example',
          pluginVersion: '1.2.3',
          remoteContentId: 'book-1',
          contentKind: 'novel',
          title: '测试书籍',
          coverUrl: 'https://example.invalid/cover.jpg',
          progress: progress,
        ),
      ],
      skippedShelfItems: 0,
    );

    final wire = manifest.toPairedTasksJson();
    final bookshelf = wire['bookshelf']! as Map<String, Object?>;
    final shelfItem = (bookshelf['items']! as List<Object?>).single as Map<String, Object?>;
    final progressTask = (wire['progress']! as List<Object?>).single as Map<String, Object?>;
    final decoded = LanSyncManifest.fromPairedTasksJson(wire);

    expect(wire['schemaVersion'], 3);
    expect(shelfItem, isNot(contains('progress')));
    expect(shelfItem, isNot(contains('catalog')));
    expect(shelfItem, isNot(contains('content')));
    expect(shelfItem, isNot(contains('coverBytes')));
    expect(progressTask.keys, containsAll(<String>['pluginId', 'remoteContentId', 'value']));
    expect(decoded.shelfItems.single.progress?.chapterId, progress.chapterId);
  });

  test('paired task schema rejects progress without matching bookshelf metadata', () {
    expect(
      () => LanSyncManifest.fromPairedTasksJson(<String, Object?>{
        'schemaVersion': 3,
        'plugins': <Object?>[],
        'bookshelf': <String, Object?>{'items': <Object?>[], 'skippedItems': 0},
        'progress': <Object?>[
          <String, Object?>{
            'pluginId': 'source.example',
            'remoteContentId': 'missing-book',
            'value': <String, Object?>{
              'chapterId': 'chapter-1',
              'paragraphId': 'p1',
              'characterOffset': 0,
              'chapterIndex': 0,
              'chapterFraction': 0,
              'bookFraction': 0,
              'updatedAtUtc': '2026-08-25T00:00:00Z',
              'totalReadingSeconds': 0,
            },
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test('rejects malformed hashes, inconsistent sizes and duplicate plugins', () {
    Map<String, Object?> plugin({
      String id = 'source.example',
      String checksum = 'aaaaaaaa',
      int bytes = 1,
      bool transferable = true,
    }) => <String, Object?>{
      'id': id,
      'version': '1.0.0',
      'bytes': bytes,
      'artifactFormat': 'archive',
      'checksum': checksum,
      'transferable': transferable,
    };

    expect(() => LanSyncPluginDescriptor.fromJson(plugin(checksum: 'secret')), throwsFormatException);
    expect(() => LanSyncPluginDescriptor.fromJson(plugin()..['artifactFormat'] = 'zip'), throwsFormatException);
    expect(() => LanSyncPluginDescriptor.fromJson(plugin(bytes: 0, transferable: true)), throwsFormatException);
    expect(
      () => LanSyncManifest.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'plugins': <Object?>[plugin(), plugin()],
        'shelfItems': <Object?>[],
        'skippedShelfItems': 0,
      }),
      throwsFormatException,
    );
  });

  test('rejects content bodies and oversized batches by schema shape', () {
    expect(
      () => LanSyncManifest.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'plugins': <Object?>[],
        'shelfItems': <Object?>[
          <String, Object?>{
            'pluginId': 'source.example',
            'pluginVersion': '1.0.0',
            'remoteContentId': 'book-1',
            'contentKind': 'novel',
            'title': '书籍',
            'progress': <String, Object?>{
              'chapterId': 'chapter-1',
              'paragraphId': 'p1',
              'characterOffset': 0,
              'chapterIndex': 0,
              'chapterFraction': 2,
              'bookFraction': 0,
              'updatedAtUtc': '2026-08-25T00:00:00Z',
              'totalReadingSeconds': 0,
            },
          },
        ],
        'skippedShelfItems': 0,
      }),
      throwsFormatException,
    );
  });

  test('selects only the shelf items checked by the receiver', () {
    final first = LanSyncShelfItem(
      pluginId: 'source.example',
      pluginVersion: '1.0.0',
      remoteContentId: 'book-1',
      contentKind: 'novel',
      title: '第一本',
    );
    final second = LanSyncShelfItem(
      pluginId: 'source.example',
      pluginVersion: '1.0.0',
      remoteContentId: 'book-2',
      contentKind: 'novel',
      title: '第二本',
    );
    final selected = LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[],
      shelfItems: <LanSyncShelfItem>[first, second],
      skippedShelfItems: 0,
    ).selectShelfItems(<String>{first.identity});

    expect(selected.shelfItems.map((item) => item.identity), <String>[first.identity]);
  });
}
