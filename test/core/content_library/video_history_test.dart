import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-video-history-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('persists history for unshelved source media across reopen', () async {
    final checkpoint = _checkpoint();
    final result = await library.saveVideoHistory(checkpoint);

    expect(result.status, VideoHistorySaveStatus.committed);
    expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);

    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    final restored = await library.readVideoHistory(checkpoint.sourceKey);
    expect(restored?.checkpoint.toJson(), checkpoint.toJson());
    expect(restored?.revision, 1);
  });

  test('keys history by plugin and content identity without favorite membership', () async {
    final first = _checkpoint(pluginId: 'source-a', contentId: 'same-id');
    final second = _checkpoint(pluginId: 'source-b', contentId: 'same-id');
    await library.saveVideoHistory(first);
    await library.saveVideoHistory(second);

    expect(await library.readVideoHistory(first.sourceKey), isNotNull);
    expect(await library.readVideoHistory(second.sourceKey), isNotNull);
    expect((await library.listVideoHistory()).map((entry) => entry.checkpoint.pluginId).toSet(), {'source-a', 'source-b'});
    expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);

    final ambiguousA = _checkpoint(pluginId: 'left\u001fmiddle', contentId: 'right');
    final ambiguousB = _checkpoint(pluginId: 'left', contentId: 'middle\u001fright');
    expect(ambiguousA.sourceKey, isNot(ambiguousB.sourceKey));
    expect(videoHistoryRecordId(ambiguousA.sourceKey), isNot(videoHistoryRecordId(ambiguousB.sourceKey)));
  });

  test('rejects local paths, credential query fields, and unknown serialized fields', () async {
    expect(() => _checkpoint(contentId: r'C:\Private\video.mp4').toJson(), throwsFormatException);
    expect(() => _checkpoint(contentId: 'https://example.test/watch?token=secret').toJson(), throwsFormatException);
    expect(
      () => VideoHistoryCheckpoint.fromJson({..._checkpoint().toJson(), 'resolvedUrl': 'https://example.test/stream'}),
      throwsFormatException,
    );
  });

  test('remote CAS conflict preserves both the current pointer and device branch', () async {
    final local = _checkpoint(origin: 'tv', session: 'tv-session', generation: 4, sequence: 9);
    await library.saveVideoHistory(local);
    final remote = _checkpoint(origin: 'phone', session: 'phone-session', generation: 8, sequence: 3);
    final result = await library.saveVideoHistory(remote, remote: true, expectedLocalRevision: 0);

    expect(result.status, VideoHistorySaveStatus.conflict);
    expect((await library.readVideoHistory(local.sourceKey))?.checkpoint.originDeviceId, 'tv');
    final branches = await library.listVideoHistory(includeRemoteBranches: true, limit: 10);
    expect(branches.map((entry) => entry.checkpoint.originDeviceId), containsAll(['tv', 'phone']));
    expect((await library.listVideoHistory(limit: 10)).single.checkpoint.originDeviceId, 'tv');
  });

  test('deduplicates sequence and fences old sessions by local generation', () async {
    final current = _checkpoint(origin: 'tv', session: 'session-1', generation: 7, sequence: 20);
    final first = await library.saveVideoHistory(current);
    final duplicate = await library.saveVideoHistory(current);
    expect(first.status, VideoHistorySaveStatus.committed);
    expect(duplicate.status, VideoHistorySaveStatus.duplicate);
    expect((await library.saveVideoHistory(current.copyWith(sequence: 19))).status, VideoHistorySaveStatus.conflict);

    final sameGenerationNewSession = await library.saveVideoHistory(current.copyWith(session: 'session-2', sequence: 0));
    expect(sameGenerationNewSession.status, VideoHistorySaveStatus.conflict);

    final newerGeneration = await library.saveVideoHistory(
      current.copyWith(session: 'session-2', generation: 8, sequence: 0, updatedAt: DateTime.utc(2020)),
    );
    expect(newerGeneration.status, VideoHistorySaveStatus.committed);

    final delayedOldSession = await library.saveVideoHistory(current.copyWith(sequence: 999, updatedAt: DateTime.utc(2036)));
    expect(delayedOldSession.status, VideoHistorySaveStatus.conflict);
    final saved = (await library.readVideoHistory(current.sourceKey))!.checkpoint;
    expect(saved.playbackSessionId, 'session-2');
    expect(saved.localGeneration, 8);
    expect(saved.sequence, 0);
  });

  test('remote writes require expected revision and concurrent writers use CAS', () async {
    final a = _checkpoint(origin: 'phone-a', session: 'a', generation: 1, sequence: 1);
    final b = _checkpoint(origin: 'phone-b', session: 'b', generation: 1, sequence: 1);
    await expectLater(library.saveVideoHistory(a, remote: true), throwsArgumentError);

    final results = await Future.wait([
      library.saveVideoHistory(a, remote: true, expectedLocalRevision: 0),
      library.saveVideoHistory(b, remote: true, expectedLocalRevision: 0),
    ]);
    expect(results.map((result) => result.status).toSet(), {VideoHistorySaveStatus.committed, VideoHistorySaveStatus.conflict});
    expect(await library.readVideoHistory(a.sourceKey), isNotNull);
    final branches = await library.listVideoHistory(includeRemoteBranches: true, limit: 10);
    expect(branches.map((entry) => entry.checkpoint.originDeviceId).toSet(), {'phone-a', 'phone-b'});
  });

  test('branch and resume records stay within the combined 500 record cap', () async {
    for (var index = 0; index < 251; index++) {
      await library.saveVideoHistory(_checkpoint(contentId: 'cap-$index'));
    }

    expect(await library.listVideoHistory(includeRemoteBranches: true, limit: 500), hasLength(500));
    expect(await library.listVideoHistory(limit: 500), hasLength(251));
    await expectLater(library.listVideoHistory(limit: 501), throwsArgumentError);
  });

  test('persistence errors surface to the caller', () async {
    await library.close();
    await expectLater(library.saveVideoHistory(_checkpoint()), throwsA(isA<PersistenceClosedError>()));
  });
}

VideoHistoryCheckpoint _checkpoint({
  String pluginId = 'fixture-source',
  String contentId = 'video-1',
  String origin = 'tv',
  String session = 'session-1',
  int generation = 1,
  int sequence = 1,
  int positionMs = 12000,
}) => VideoHistoryCheckpoint(
  pluginId: pluginId,
  contentId: contentId,
  pluginVersion: '1.0.0',
  title: '测试视频',
  groupId: 'group-1',
  episodeId: 'episode-1',
  position: Duration(milliseconds: positionMs),
  duration: const Duration(minutes: 30),
  originDeviceId: origin,
  playbackSessionId: session,
  sequence: sequence,
  localGeneration: generation,
  updatedAtUtc: DateTime.utc(2026, 11, 4),
);

extension on VideoHistoryCheckpoint {
  VideoHistoryCheckpoint copyWith({String? session, int? generation, int? sequence, DateTime? updatedAt}) => VideoHistoryCheckpoint(
    pluginId: pluginId,
    contentId: contentId,
    pluginVersion: pluginVersion,
    title: title,
    groupId: groupId,
    episodeId: episodeId,
    position: position,
    duration: duration,
    originDeviceId: originDeviceId,
    playbackSessionId: session ?? playbackSessionId,
    sequence: sequence ?? this.sequence,
    localGeneration: generation ?? localGeneration,
    updatedAtUtc: updatedAt ?? updatedAtUtc,
  );
}
