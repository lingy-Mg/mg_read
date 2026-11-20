/// Exercises the transfer against real loopback HTTP, including concurrent
/// segment ordering, origin-scoped headers, and incomplete-job cleanup.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/data/source_video_transfer.dart';

void main() {
  late Directory destination;
  late HttpServer server;
  late Uri base;

  setUp(() async {
    destination = await Directory.systemTemp.createTemp('source-video-transfer-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
    await destination.delete(recursive: true);
  });

  test('streams progressive media with the source headers and reports actual size', () async {
    final payload = _box('ftyp');
    String? referer;
    server.listen((request) async {
      referer = request.headers.value('referer');
      request.response.contentLength = payload.length;
      request.response.add(payload.take(4).toList());
      await request.response.flush();
      request.response.add(payload.skip(4).toList());
      await request.response.close();
    });

    final progress = <(int, int?)>[];
    final result = await downloadSourceVideo(
      uri: base.resolve('/opaque'),
      headers: {'Referer': 'https://example.test/'},
      directory: destination,
      onProgress: (received, total) => progress.add((received, total)),
    );

    expect(referer, 'https://example.test/');
    expect(result.extension, 'mp4');
    expect(result.mimeType, 'video/mp4');
    expect(await result.file.readAsBytes(), payload);
    expect(progress.first, (0, payload.length));
    expect(progress.last, (payload.length, payload.length));
    expect(await destination.list().map((entity) => entity.path).toList(), [result.file.path]);
  });

  test('loads a redirected master and concurrently writes MPEG-TS in playlist order', () async {
    final first = _packet(1);
    final second = _packet(2);
    final secondRequested = Completer<void>();
    server.listen((request) async {
      switch (request.uri.path) {
        case '/opaque':
          request.response.redirect(base.resolve('/hls/master'));
        case '/hls/master':
          request.response.write('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="separate",NAME="Audio",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800,AUDIO="separate"
unsupported.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=500
playlist
#EXT-X-STREAM-INF:BANDWIDTH=100
lower.m3u8
''');
          await request.response.close();
        case '/hls/playlist':
          request.response.write('''#EXTM3U
#EXTINF:1,
one.ts
#EXTINF:1,
two.ts
#EXT-X-ENDLIST
''');
          await request.response.close();
        case '/hls/one.ts':
          await secondRequested.future.timeout(const Duration(seconds: 3));
          request.response.add(first);
          await request.response.close();
        case '/hls/two.ts':
          secondRequested.complete();
          request.response.add(second);
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    });

    final result = await downloadSourceVideo(uri: base.resolve('/opaque'), headers: {}, directory: destination, onProgress: (_, _) {});

    expect(result.extension, 'ts');
    expect(result.mimeType, 'video/mp2t');
    expect(await result.file.readAsBytes(), [...first, ...second]);
  });

  test('builds an MP4 with initialization and ordered byte ranges', () async {
    final initialization = _box('ftyp');
    final first = _box('moof');
    final second = _box('styp');
    final entireFile = [...initialization, ...first, ...second];
    final ranges = <String>[];
    server.listen((request) async {
      if (request.uri.path == '/playlist') {
        request.response.write('''#EXTM3U
#EXT-X-MAP:URI="media",BYTERANGE="16@0"
#EXTINF:1,
#EXT-X-BYTERANGE:16@16
media
#EXTINF:1,
#EXT-X-BYTERANGE:16
media
#EXT-X-ENDLIST
''');
      } else {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        ranges.add(range);
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final start = int.parse(match[1]!);
        final end = int.parse(match[2]!);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${entireFile.length}');
        request.response.add(entireFile.sublist(start, end + 1));
      }
      await request.response.close();
    });

    final result = await downloadSourceVideo(uri: base.resolve('/playlist'), headers: {}, directory: destination, onProgress: (_, _) {});

    expect(ranges, unorderedEquals(['bytes=0-15', 'bytes=16-31', 'bytes=32-47']));
    expect(result.extension, 'mp4');
    expect(await result.file.readAsBytes(), entireFile);
  });

  test('cancels an active download and removes unfinished cache files', () async {
    final cancellation = Completer<void>();
    final sent = Completer<void>();
    server.listen((request) async {
      request.response.add(_box('ftyp'));
      await request.response.flush();
      sent.complete();
    });
    final result = downloadSourceVideo(
      uri: base.resolve('/opaque'),
      headers: {},
      directory: destination,
      onProgress: (_, _) {},
      cancellation: cancellation.future,
    );
    final failed = expectLater(result, throwsA(anything));

    await sent.future;
    cancellation.complete();
    await failed;
    expect(await destination.list().toList(), isEmpty);
  });
}

List<int> _box(String type) => [0, 0, 0, 16, ...ascii.encode(type), ...List.filled(8, 0)];

List<int> _packet(int payload) => [0x47, 0, 0, 0x10, ...List.filled(184, payload)];
