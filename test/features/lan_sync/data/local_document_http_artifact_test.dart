import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/local_document_http_artifact.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('rejects a chunked body as soon as it exceeds the descriptor byte count', () async {
    final declared = <int>[1, 2, 3, 4];
    final descriptor = _descriptor(declared);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      request.response.headers.set(HttpHeaders.etagHeader, _etag(descriptor.rawSha256));
      request.response.add(<int>[...declared, 5]);
      await request.response.close();
    });
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
    });

    await expectLater(
      const LanSyncLocalDocumentHttpClient().download(_uri(server), descriptor),
      throwsA(isA<LanSyncTransportException>().having((error) => error.code, 'code', 'lan_sync_local_document_size_mismatch')),
    );
  });

  test('rejects a partial response whose Content-Range does not match the requested bytes', () async {
    final bytes = <int>[10, 11, 12, 13, 14, 15];
    final descriptor = _descriptor(bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      final response = request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = bytes.length;
      response.headers
        ..set(HttpHeaders.etagHeader, _etag(descriptor.rawSha256))
        ..set(HttpHeaders.contentRangeHeader, 'bytes 0-4/${bytes.length}');
      response.add(bytes);
      await response.close();
    });
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
    });

    await expectLater(
      const LanSyncLocalDocumentHttpClient().download(_uri(server), descriptor),
      throwsA(isA<LanSyncTransportException>().having((error) => error.code, 'code', 'lan_sync_local_document_range_mismatch')),
    );
  });

  test('resumes a disconnected response with Range and If-Range then verifies the full SHA-256', () async {
    final bytes = List<int>.generate(128, (index) => index);
    final descriptor = _descriptor(bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    String? observedRange;
    String? observedIfRange;
    final serving = server.listen((request) async {
      requestCount++;
      final response = request.response;
      response.headers.set(HttpHeaders.etagHeader, _etag(descriptor.rawSha256));
      if (requestCount == 1) {
        response.contentLength = bytes.length;
        final socket = await response.detachSocket(writeHeaders: true);
        socket.add(bytes.sublist(0, 37));
        await socket.flush();
        await socket.close();
        return;
      }
      observedRange = request.headers.value(HttpHeaders.rangeHeader);
      observedIfRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final start = int.parse(observedRange!.replaceFirst('bytes=', '').replaceFirst('-', ''));
      final remainder = bytes.sublist(start);
      response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = remainder.length;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${bytes.length - 1}/${bytes.length}');
      response.add(remainder);
      await response.close();
    });
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
    });

    final stream = await const LanSyncLocalDocumentHttpClient().download(_uri(server), descriptor).timeout(const Duration(seconds: 15));
    final received = await stream.expand((chunk) => chunk).toList();
    expect(received, bytes);
    expect(requestCount, 2);
    expect(observedRange, 'bytes=37-');
    expect(observedIfRange, _etag(descriptor.rawSha256));
    expect(crypto.sha256.convert(received).toString(), descriptor.rawSha256);
  });

  test('cancelling or disposing an unconsumed downloaded stream removes its temporary file', () async {
    final bytes = <int>[7, 6, 5, 4, 3, 2, 1];
    final descriptor = _descriptor(bytes);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.listen((request) async {
      request.response.headers
        ..set(HttpHeaders.etagHeader, _etag(descriptor.rawSha256))
        ..contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    addTearDown(() async {
      await serving.cancel();
      await server.close(force: true);
    });

    final stream = await const LanSyncLocalDocumentHttpClient().download(_uri(server), descriptor);
    final leaseDirectory = (stream as dynamic).directory as Directory;
    expect(await leaseDirectory.exists(), isTrue);
    final subscription = stream.listen((_) {});
    await subscription.cancel();
    await (stream as dynamic).dispose();
    expect(await leaseDirectory.exists(), isFalse);
    final unconsumed = await const LanSyncLocalDocumentHttpClient().download(_uri(server), descriptor);
    final unusedDirectory = (unconsumed as dynamic).directory as Directory;
    await discardLocalDocumentStream(unconsumed).timeout(const Duration(seconds: 3));
    expect(await unusedDirectory.exists(), isFalse);
  });
}

LanSyncLocalDocumentDescriptor _descriptor(List<int> bytes) => LanSyncLocalDocumentDescriptor(
  documentId: 'local-document-test-id',
  rawSha256: crypto.sha256.convert(bytes).toString(),
  originalBytes: bytes.length,
  format: 'txt',
  title: 'test',
  options: const <String, Object?>{},
);

Uri _uri(HttpServer server) => Uri(scheme: 'http', host: server.address.address, port: server.port, path: '/document');

String _etag(String hash) => '"sha256-$hash"';
