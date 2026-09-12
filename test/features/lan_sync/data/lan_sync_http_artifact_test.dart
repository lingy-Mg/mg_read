/// 使用真实 dart:io HTTP 客户端/服务端验证标准制品响应，不以伪造调用代替协议行为。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
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
    expect(response.headers.value(HttpHeaders.etagHeader), '"crc32-${lanSyncChecksum(bytes)}"');
    expect(await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)), bytes);
  });

  test('Range and If-Range return 206 for the fixed generation', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(uri);
    request.headers
      ..set(HttpHeaders.rangeHeader, 'bytes=4-7')
      ..set(HttpHeaders.ifRangeHeader, '"crc32-${lanSyncChecksum(bytes)}"');
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
    final progress = <List<int>>[];
    final stream = await const LanSyncHttpArtifactClient().download(
      uri,
      _descriptor(bytes),
      onVerificationProgress: (completed, total) => progress.add(<int>[completed, total]),
    );
    expect(await stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)), bytes);
    expect(progress, isNotEmpty);
    expect(progress.last, <int>[bytes.length, bytes.length]);
  });

  test('client rejects bytes that keep the declared length but fail the hash', () async {
    await server.close(force: true);
    final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(rawServer.close);
    rawServer.listen((socket) async {
      await _readRequestHeader(socket);
      socket.add(
        utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 10\r\n'
          'ETag: "crc32-${lanSyncChecksum(bytes)}"\r\n'
          'Connection: close\r\n\r\n'
          'abcdefghij',
        ),
      );
      await socket.flush();
      await socket.close();
    });
    uri = Uri.parse('http://${rawServer.address.address}:${rawServer.port}/artifact');

    await expectLater(
      const LanSyncHttpArtifactClient().download(uri, _descriptor(bytes)),
      throwsA(isA<LanSyncTransportException>().having((error) => error.code, 'code', 'lan_sync_plugin_hash_mismatch')),
    );
  });

  test('client resumes an interrupted response from the received byte offset', () async {
    await server.close(force: true);
    var requests = 0;
    String? resumedRange;
    final rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(rawServer.close);
    rawServer.listen((socket) async {
      requests++;
      final requestHeader = await _readRequestHeader(socket);
      if (requests == 1) {
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Length: ${bytes.length}\r\n'
            'ETag: "crc32-${lanSyncChecksum(bytes)}"\r\n'
            'Connection: close\r\n\r\n'
            '0123',
          ),
        );
        await socket.flush();
        socket.destroy();
        return;
      }
      resumedRange = RegExp(r'^Range:\s*([^\r\n]+)', caseSensitive: false, multiLine: true).firstMatch(requestHeader)?.group(1);
      socket.add(
        utf8.encode(
          'HTTP/1.1 206 Partial Content\r\n'
          'Content-Length: 6\r\n'
          'Content-Range: bytes 4-9/10\r\n'
          'ETag: "crc32-${lanSyncChecksum(bytes)}"\r\n'
          'Connection: close\r\n\r\n'
          '456789',
        ),
      );
      await socket.flush();
      await socket.close();
    });
    uri = Uri.parse('http://${rawServer.address.address}:${rawServer.port}/artifact');

    final stream = await const LanSyncHttpArtifactClient().download(uri, _descriptor(bytes));

    expect(await stream.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)), bytes);
    expect(resumedRange, 'bytes=4-');
    expect(requests, 2);
  });

  test('materialization rejects a generation whose declared hash changed', () async {
    final descriptor = _descriptor(bytes, sha: 'a' * 64);
    await expectLater(
      LanSyncHttpArtifact.materialize(descriptor, Stream.value(bytes)),
      throwsA(isA<LanSyncTransportException>().having((error) => error.code, 'code', 'lan_sync_plugin_hash_mismatch')),
    );
  });
}

Future<String> _readRequestHeader(Socket socket) {
  final completed = Completer<String>();
  final bytes = <int>[];
  late StreamSubscription<List<int>> subscription;
  subscription = socket.listen(
    (chunk) {
      bytes.addAll(chunk);
      final text = ascii.decode(bytes, allowInvalid: true);
      if (!text.contains('\r\n\r\n') || completed.isCompleted) return;
      completed.complete(text);
      unawaited(subscription.cancel());
    },
    onError: completed.completeError,
    onDone: () {
      if (!completed.isCompleted) completed.complete(ascii.decode(bytes, allowInvalid: true));
    },
  );
  return completed.future.timeout(const Duration(seconds: 2));
}

LanSyncPluginDescriptor _descriptor(List<int> bytes, {String? sha}) => LanSyncPluginDescriptor(
  id: 'source.http-test',
  version: '1.0.0',
  bytes: bytes.length,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  checksum: sha ?? lanSyncChecksum(bytes),
  transferable: true,
);
