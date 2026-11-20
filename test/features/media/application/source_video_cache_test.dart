/// Offline video publication, task identity, cancellation, and file leasing.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_video_cache.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

const _first = (pluginId: 'source', contentId: 'series', groupId: 'line-a', episodeId: 'episode');
const _second = (pluginId: 'source', contentId: 'series', groupId: 'line-b', episodeId: 'episode');

void main() {
  late Directory support;
  late SourceVideoCache cache;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('mg-read-video-cache-');
    cache = SourceVideoCache(supportDirectory: () async => support, parallelDownloads: 1);
  });

  tearDown(() async {
    cache.dispose();
    await support.delete(recursive: true);
  });

  test('deduplicates a download and restores only complete files by the full episode identity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bytes = Uint8List.fromList([0, 0, 0, 24, ...'ftypisom'.codeUnits, ...List.filled(12, 0)]);
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.headers.value('X-Source-Token'), 'transient-test-header');
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.contentLength = bytes.length;
      if (request.method != 'HEAD') request.response.add(bytes);
      await request.response.close();
    });
    final uri = Uri.http('127.0.0.1:${server.port}', '/episode.mp4', {'token': 'transient-test-url'});
    var resolutions = 0;
    Future<SourceVideoCacheEntry> download(SourceVideoCacheKey key) => cache.download(
      key: key,
      title: 'Series',
      episodeTitle: 'First/episode',
      resolve: () async {
        resolutions++;
        return VideoEpisode(
          id: key.episodeId,
          title: 'First/episode',
          uri: '$uri',
          httpHeaders: {'X-Source-Token': 'transient-test-header'},
        );
      },
    );
    final results = await Future.wait([download(_first), download(_first)]);
    expect(
      results.map((entry) => entry.status),
      everyElement(SourceVideoCacheStatus.completed),
      reason: results.map((entry) => entry.error).join(),
    );
    expect(resolutions, 1);
    expect(requests, greaterThan(0));
    expect(await cache.findPlaybackUri(_second), isNull);
    final cached = (await cache.findPlaybackUri(_first))!;
    expect(cached.scheme, 'file');
    expect(await File.fromUri(cached).readAsBytes(), bytes);
    final manifest = await File('${File.fromUri(cached).parent.path}${Platform.pathSeparator}entry.json').readAsString();
    expect(manifest, isNot(contains('transient-test-')));

    await File.fromUri(cached).delete();
    expect(await cache.findPlaybackUri(_first), isNull);
    expect(cache.entryOf(_first)?.status, SourceVideoCacheStatus.failed);
    final repaired = await download(_first);
    expect(repaired.status, SourceVideoCacheStatus.completed, reason: repaired.error);
    expect(resolutions, 2);

    final reopened = SourceVideoCache(supportDirectory: () async => support);
    addTearDown(reopened.dispose);
    await reopened.ready;
    expect(reopened.entries.single.key, _first);
    final saved = await reopened.withExportFile(_first, (file, name, mimeType) async {
      expect(name, 'Series - First_episode.mp4');
      expect(mimeType, 'video/mp4');
      await expectLater(reopened.remove(_first), throwsA(isA<SourceVideoCacheException>()));
      return await file.readAsBytes();
    });
    expect(saved, bytes);
    await reopened.remove(_first);
    expect(await File.fromUri(cached).exists(), isFalse);
    expect(reopened.entries, isEmpty);
  });

  test('cancels resolving and queued jobs without publishing a cache entry', () async {
    final firstStarted = Completer<void>();
    final blockedResolution = Completer<VideoEpisode>();
    final first = cache.download(
      key: _first,
      title: 'Series',
      episodeTitle: 'First',
      resolve: () {
        firstStarted.complete();
        return blockedResolution.future;
      },
    );
    await firstStarted.future;
    final queued = Completer<void>();
    cache.addListener(() {
      if (!queued.isCompleted && cache.entryOf(_second)?.status == SourceVideoCacheStatus.queued) queued.complete();
    });
    var secondResolved = false;
    final second = cache.download(
      key: _second,
      title: 'Series',
      episodeTitle: 'First',
      resolve: () async {
        secondResolved = true;
        throw StateError('this queued resolver must not be called');
      },
    );
    await queued.future;
    await cache.remove(_second);
    await cache.remove(_first);
    blockedResolution.completeError(StateError('late resolver failure'));
    expect(secondResolved, isFalse);
    expect((await first).status, SourceVideoCacheStatus.failed);
    expect((await second).status, SourceVideoCacheStatus.failed);
    expect(cache.entries, isEmpty);
  });
}
