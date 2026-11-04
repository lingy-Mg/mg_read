import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-video-generation-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('concurrent reservations for one origin are unique and monotonic', () async {
    final reserved = await Future.wait([
      library.allocateVideoHistoryGeneration('tv-device'),
      library.allocateVideoHistoryGeneration('tv-device'),
    ]);

    expect(reserved.toSet(), hasLength(2));
    expect(reserved.toList()..sort(), [1, 2]);
    expect(await library.allocateVideoHistoryGeneration('tv-device'), 3);
  });

  test('generation counters are independent for each origin', () async {
    expect(await library.allocateVideoHistoryGeneration('tv-device'), 1);
    expect(await library.allocateVideoHistoryGeneration('phone-device'), 1);
    expect(await library.allocateVideoHistoryGeneration('tv-device'), 2);
  });

  test('reservation is durable across ContentLibrary reopen', () async {
    expect(await library.allocateVideoHistoryGeneration('tv-device'), 1);
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);

    expect(await library.allocateVideoHistoryGeneration('tv-device'), 2);
  });

  test('first reservation seeds above a retained branch generation independent of timestamp', () async {
    final checkpoint = VideoHistoryCheckpoint(
      pluginId: 'fixture-source',
      contentId: 'video-1',
      pluginVersion: '1.0',
      title: '测试视频',
      groupId: 'group-1',
      episodeId: 'episode-1',
      position: Duration.zero,
      duration: const Duration(minutes: 30),
      originDeviceId: 'tv-device',
      playbackSessionId: 'old-session',
      sequence: 999,
      localGeneration: 40,
      updatedAtUtc: DateTime.utc(2000),
    );
    await library.saveVideoHistory(checkpoint);

    expect(await library.allocateVideoHistoryGeneration('tv-device'), 41);
  });
}
