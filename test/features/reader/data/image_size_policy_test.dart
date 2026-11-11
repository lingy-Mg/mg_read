/// Exercises the production HTTP entrances with declared and chunked image bodies.
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/discovery/data/content_library_source_cover_persistence.dart';
import 'package:mg_read/features/reader/data/comic_image_transport.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient()..findProxy = (_) => 'DIRECT';
    server.listen((request) async {
      final size = int.parse(request.uri.queryParameters['bytes']!);
      request.response.headers.contentType = ContentType('image', 'png');
      if (request.uri.path == '/declared') request.response.contentLength = size;
      try {
        await request.response.addStream(_pngBytes(size));
        await request.response.close();
      } on Object {
        // The receiving limit intentionally cancels oversize streams.
      }
    });
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });
  Uri url(int bytes, {bool declared = true}) =>
      Uri.parse('http://127.0.0.1:${server.port}/${declared ? 'declared' : 'chunked'}?bytes=$bytes');

  test('a 6 MiB cover passes the previous download barrier', () async {
    expect((await fetchSourceCover(url(6 * 1024 * 1024), client: client))?.length, 6 * 1024 * 1024);
  });
  test('cover download accepts exactly 50 MiB', () async {
    expect((await fetchSourceCover(url(50 * 1024 * 1024), client: client))?.length, 50 * 1024 * 1024);
  });
  test('comic download accepts exactly 50 MiB', () async {
    expect((await fetchComicImage(url(50 * 1024 * 1024), client: client)).length, 50 * 1024 * 1024);
  });
  for (final declared in [true, false]) {
    test('cover rejects 50 MiB plus one byte (declared=$declared)', () async {
      expect(await fetchSourceCover(url(50 * 1024 * 1024 + 1, declared: declared), client: client), isNull);
    });
    test('comic rejects 50 MiB plus one byte with a detailed reason (declared=$declared)', () async {
      await expectLater(
        fetchComicImage(url(50 * 1024 * 1024 + 1, declared: declared), client: client),
        throwsA(isA<StateError>().having((e) => e.message, 'size reason', contains('52428800'))),
      );
    });
  }
}

Stream<List<int>> _pngBytes(int length) async* {
  yield Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
  var remaining = length - 8;
  final chunk = Uint8List(64 * 1024);
  while (remaining > 0) {
    final size = remaining < chunk.length ? remaining : chunk.length;
    yield size == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, size);
    remaining -= size;
  }
}
