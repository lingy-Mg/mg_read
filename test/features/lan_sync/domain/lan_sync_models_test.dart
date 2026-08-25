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
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
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
    expect(decoded.shelfItems.single.identity, 'source.example\u001fbook-1');
    expect(decoded.shelfItems.single.progress?.chapterIndex, 1);
    expect(decoded.skippedShelfItems, 1);
  });

  test(
    'rejects malformed hashes, inconsistent sizes and duplicate plugins',
    () {
      Map<String, Object?> plugin({
        String id = 'source.example',
        String sha256 =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        int bytes = 1,
        bool transferable = true,
      }) => <String, Object?>{
        'id': id,
        'version': '1.0.0',
        'bytes': bytes,
        'sha256': sha256,
        'transferable': transferable,
      };

      expect(
        () => LanSyncPluginDescriptor.fromJson(plugin(sha256: 'secret')),
        throwsFormatException,
      );
      expect(
        () => LanSyncPluginDescriptor.fromJson(
          plugin(bytes: 0, transferable: true),
        ),
        throwsFormatException,
      );
      expect(
        () => LanSyncManifest.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'plugins': <Object?>[plugin(), plugin()],
          'shelfItems': <Object?>[],
          'skippedShelfItems': 0,
        }),
        throwsFormatException,
      );
    },
  );

  test('rejects content bodies and oversized batches by schema shape', () {
    expect(
      () => LanSyncManifest.fromJson(<String, Object?>{
        'schemaVersion': 1,
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
}
