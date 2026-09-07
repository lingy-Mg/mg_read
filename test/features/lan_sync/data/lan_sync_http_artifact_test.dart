/// 使用真实 dart:io HTTP 客户端/服务端验证标准制品响应，不以伪造调用代替协议行为。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_artifact.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  final bytes = utf8.encode('0123456789');
  late LanSyncHttpArtifact artifact;
  late HttpServer server;
  late Uri uri;

  setUp(() async {
    artifact = await LanSyncHttpArtifact.materialize(_descriptor(bytes), Stream.value(bytes));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(artifact.serve);
    uri = Uri.parse('http://${server.address.address}:${server.port}/artifact');
  });

  tearDown(() async {
    await server.close(force: true);
    await artifact.close();
  });

  test('GET serves immutable artifact with ETag and range support', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(uri);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(response.headers.value(HttpHeaders.etagHeader), '"sha256-${sha256.convert(bytes)}"');
    expect(await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)), bytes);
  });

  test('Range and If-Range return 206 for the fixed generation', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(uri);
    request.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=4-7')
      ..set(HttpHeaders.ifRangeHeader, '"sha256-${sha256.convert(bytes)}"');
    final response = await request.close();
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 4-7/10');
    expect(await utf8.decodeStream(response), '4567');
  });

  test('changed If-Range restarts with 200 and invalid range returns 416', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final changed = await client.getUrl(uri);
    changed.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=4-')
      ..set(HttpHeaders.ifRangeHeader, '"sha256-old"');
    final restarted = await changed.close();
    expect(restarted.statusCode, HttpStatus.ok);
    expect(await utf8.decodeStream(restarted), '0123456789');

    final invalid = await client.getUrl(uri);
    invalid.headers.set(HttpHeaders.rangeHeader, 'bytes=10-');
    final rejected = await invalid.close();
    expect(rejected.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(rejected.headers.value(HttpHeaders.contentRangeHeader), 'bytes */10');
    await rejected.drain<void>();
  });

  test('client verifies length and hash before exposing install stream', () async {
    final stream = await const LanSyncHttpArtifactClient().download(uri, _descriptor(bytes));
    expect(await stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)), bytes);
  });

  test('materialization rejects a generation whose declared hash changed', () async {
    final descriptor = _descriptor(bytes, sha: 'a' * 64);
    await expectLater(
      LanSyncHttpArtifact.materialize(descriptor, Stream.value(bytes)),
      throwsA(isA<LanSyncTransportException>().having((error) => error.code, 'code', 'lan_sync_plugin_hash_mismatch')),
    );
  });
}

LanSyncPluginDescriptor _descriptor(List<int> bytes, {String? sha}) => LanSyncPluginDescriptor(
  id: 'source.http-test',
  version: '1.0.0',
  bytes: bytes.length,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  sha256: sha ?? sha256.convert(bytes).toString(),
  transferable: true,
);
