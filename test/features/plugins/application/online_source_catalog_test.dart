/// Online metadata parsing must not download payloads to classify sources.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';

void main() {
  test('online catalog preserves kinds and explicit R18 flags without opening payloads', () async {
    final collection = await _load([
      _row('mixed', {
        'contentKinds': ['manga', 'video'],
        'r18': true,
      }),
      _row('music', {
        'contentKinds': ['audio'],
        'r18': false,
      }),
    ]);
    expect(collection.plugins.first.contentKinds, ['manga', 'video']);
    expect(collection.plugins.first.r18, isTrue);
    expect(collection.plugins.last.contentKinds, ['audio']);
    expect(collection.plugins.last.r18, isFalse);
  });

  test('legacy online entries remain unclassified', () async {
    final collection = await _load([_row('legacy', {})], schemaVersion: 1);
    expect(collection.plugins.single.contentKinds, isEmpty);
    expect(collection.plugins.single.r18, isNull);
  });

  test('online catalog rejects malformed classification', () async {
    for (final metadata in <Map<String, Object?>>[
      {
        'contentKinds': ['unknown'],
      },
      {'contentKinds': []},
      {
        'contentKinds': ['audio', 'audio'],
      },
      {'contentKinds': 'novel'},
      {'r18': 'false'},
      {'r18': null},
    ]) {
      await expectLater(_load([_row('invalid', metadata)]), throwsA(isA<SourceCollectionImportException>()));
    }
  });
}

Map<String, Object?> _row(String id, Map<String, Object?> metadata) => {
  'id': id,
  'name': id,
  'version': '1.0.0',
  'format': 'singleFile',
  'path': 'plugins/$id.mgplugin.js',
  'url': 'https://github.com/lingy-Mg/mg_read/releases/download/source-catalog/$id.mgplugin.js',
  'bytes': 3,
  'crc32': '00000000',
  'sha256': '0' * 64,
  ...metadata,
};

Future<SourceCollection> _load(List<Map<String, Object?>> rows, {int schemaVersion = 2}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var requests = 0;
  final subscription = server.listen((request) async {
    requests++;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'format': 'mgread-online-plugin-catalog', 'schemaVersion': schemaVersion, 'plugins': rows}));
    await request.response.close();
  });
  try {
    return await OnlineSourceCatalogService(
      httpClientFactory: () async => HttpClient(),
      catalogUri: Uri.parse('http://127.0.0.1:${server.port}/catalog.json'),
    ).loadCatalog();
  } finally {
    await subscription.cancel();
    await server.close(force: true);
    expect(requests, 1, reason: 'Classification reads only catalog metadata.');
  }
}
