/// Temporary, range-readable local-book payload for paired LAN sessions.
///
/// Local originals use SHA-256 and a 256 MiB limit, separate from plugin
/// artifacts. The temporary file is deleted when its owning session closes.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_artifact.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_client.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

final class LanSyncLocalDocumentHttpArtifact {
  LanSyncLocalDocumentHttpArtifact._(this.descriptor, this._file, {required this.cover});

  final LanSyncLocalDocumentDescriptor descriptor;
  final bool cover;
  final File _file;
  bool _closed = false;

  int get bytes => cover ? descriptor.coverBytes! : descriptor.originalBytes;
  String get sha256 => cover ? descriptor.coverSha256! : descriptor.rawSha256;

  static Future<LanSyncLocalDocumentHttpArtifact> materialize(
    LanSyncLocalDocumentDescriptor descriptor,
    Stream<List<int>> bytes, {
    bool cover = false,
  }) async {
    final expectedBytes = cover ? descriptor.coverBytes : descriptor.originalBytes;
    final expectedSha256 = cover ? descriptor.coverSha256 : descriptor.rawSha256;
    final maximumBytes = cover ? lanSyncMaxLocalCoverBytes : lanSyncMaxLocalDocumentBytes;
    if (expectedBytes == null || expectedSha256 == null || expectedBytes <= 0 || expectedBytes > maximumBytes) {
      throw const LanSyncTransportException('lan_sync_local_document_too_large');
    }
    final directory = await Directory.systemTemp.createTemp('mgread-lan-local-');
    final file = File('${directory.path}${Platform.pathSeparator}original.bin');
    final sink = file.openWrite();
    var written = 0;
    var pendingBytes = 0;
    final digestSink = _DigestSink();
    var hasherClosed = false;
    final hasher = crypto.sha256.startChunkedConversion(digestSink);
    try {
      await for (final chunk in bytes.timeout(const Duration(seconds: 30))) {
        written += chunk.length;
        if (written > expectedBytes || written > maximumBytes) {
          throw const LanSyncTransportException('lan_sync_local_document_size_mismatch');
        }
        hasher.add(chunk);
        sink.add(chunk);
        pendingBytes += chunk.length;
        if (pendingBytes >= 256 * 1024) {
          await sink.flush();
          pendingBytes = 0;
        }
      }
      await sink.close();
      hasher.close();
      hasherClosed = true;
      if (written != expectedBytes || digestSink.value?.toString() != expectedSha256) {
        throw const LanSyncTransportException('lan_sync_local_document_hash_mismatch');
      }
      return LanSyncLocalDocumentHttpArtifact._(descriptor, file, cover: cover);
    } on Object {
      if (!hasherClosed) hasher.close();
      await sink.close().catchError((_) {});
      if (await file.exists()) await file.delete();
      if (await file.parent.exists()) await file.parent.delete(recursive: true);
      rethrow;
    }
  }

  String get etag => '"sha256-$sha256"';

  Stream<List<int>> openRead() {
    if (_closed) throw const LanSyncTransportException('lan_sync_connection_closed');
    return _file.openRead();
  }

  Future<void> serve(HttpRequest request) async {
    if (_closed) {
      request.response.statusCode = HttpStatus.gone;
      await request.response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }
    final response = request.response;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.etagHeader, etag)
      ..contentType = ContentType.binary;
    final rawRange = request.headers.value(HttpHeaders.rangeHeader);
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    final range = rawRange == null || (ifRange != null && ifRange != etag) ? null : _parseRange(rawRange, bytes);
    if (rawRange != null && ifRange != null && ifRange != etag) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = bytes;
    } else if (rawRange != null && range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$bytes');
      response.contentLength = 0;
      await response.close();
      return;
    } else if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.$1}-${range.$2}/$bytes');
      response.contentLength = range.$2 - range.$1 + 1;
    } else {
      response.statusCode = HttpStatus.ok;
      response.contentLength = bytes;
    }
    if (request.method == 'GET') {
      await response.addStream(_file.openRead(range?.$1 ?? 0, (range?.$2 ?? bytes - 1) + 1));
    }
    await response.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final directory = _file.parent;
    if (await _file.exists()) await _file.delete();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

typedef _Range = (int, int);

_Range? _parseRange(String raw, int length) {
  if (!raw.startsWith('bytes=') || raw.substring(6).contains(',')) return null;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(raw);
  if (match == null) return null;
  final first = match.group(1)!;
  final second = match.group(2)!;
  if (first.isEmpty) {
    final suffix = int.tryParse(second);
    if (suffix == null || suffix <= 0) return null;
    final start = length - suffix.clamp(1, length);
    return (start, length - 1);
  }
  final start = int.tryParse(first);
  final end = second.isEmpty ? length - 1 : int.tryParse(second);
  if (start == null || end == null || start < 0 || start >= length || end < start) return null;
  return (start, end.clamp(start, length - 1));
}

final class LanSyncLocalDocumentHttpClient {
  const LanSyncLocalDocumentHttpClient({this.maximumAttempts = 4});

  final int maximumAttempts;

  Future<Stream<List<int>>> download(
    Uri uri,
    LanSyncLocalDocumentDescriptor descriptor, {
    HttpClient? client,
    void Function(HttpClientRequest request, String contentChecksum)? authenticate,
    bool cover = false,
  }) async {
    final expectedBytes = cover ? descriptor.coverBytes : descriptor.originalBytes;
    final expectedSha256 = cover ? descriptor.coverSha256 : descriptor.rawSha256;
    final maximumBytes = cover ? lanSyncMaxLocalCoverBytes : lanSyncMaxLocalDocumentBytes;
    if (expectedBytes == null || expectedSha256 == null || expectedBytes <= 0 || expectedBytes > maximumBytes) {
      throw const LanSyncTransportException('lan_sync_local_document_invalid');
    }
    final ownsClient = client == null;
    final http = client ?? createLanSyncHttpClient();
    final directory = await Directory.systemTemp.createTemp('mgread-lan-local-receive-');
    final file = File('${directory.path}${Platform.pathSeparator}original.part');
    var offset = 0;
    String? etag;
    try {
      for (var attempt = 0; attempt < maximumAttempts && offset < expectedBytes; attempt++) {
        try {
          final request = await http.getUrl(uri);
          authenticate?.call(request, LanSyncHttpAuthentication.bodyHash(const <int>[]));
          if (offset > 0) {
            request.headers
              ..set(HttpHeaders.rangeHeader, 'bytes=$offset-')
              ..set(HttpHeaders.ifRangeHeader, etag!);
          }
          final response = await request.close().timeout(const Duration(seconds: 30));
          if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
            offset = 0;
            etag = null;
            await file.writeAsBytes(const <int>[]);
            continue;
          }
          if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
            throw LanSyncTransportException('lan_sync_http_failed', reason: 'status_${response.statusCode}');
          }
          final expectedEtag = '"sha256-$expectedSha256"';
          final responseEtag = response.headers.value(HttpHeaders.etagHeader);
          if (responseEtag != expectedEtag) throw const LanSyncTransportException('lan_sync_local_document_version_changed');
          if (offset > 0 && response.statusCode == HttpStatus.ok) {
            offset = 0;
            await file.writeAsBytes(const <int>[]);
          }
          if (response.statusCode == HttpStatus.partialContent &&
              response.headers.value(HttpHeaders.contentRangeHeader) != 'bytes $offset-${expectedBytes - 1}/$expectedBytes') {
            throw const LanSyncTransportException('lan_sync_local_document_range_mismatch');
          }
          if (response.contentLength > expectedBytes - offset) {
            throw const LanSyncTransportException('lan_sync_local_document_size_mismatch');
          }
          etag = responseEtag;
          final startingOffset = offset;
          var responseBytes = 0;
          var pendingBytes = 0;
          final sink = file.openWrite(mode: startingOffset == 0 ? FileMode.write : FileMode.append);
          try {
            await for (final chunk in response.timeout(const Duration(seconds: 30))) {
              responseBytes += chunk.length;
              if (startingOffset + responseBytes > expectedBytes) {
                throw const LanSyncTransportException('lan_sync_local_document_size_mismatch');
              }
              sink.add(chunk);
              pendingBytes += chunk.length;
              if (pendingBytes >= 256 * 1024) {
                await sink.flush();
                pendingBytes = 0;
              }
            }
            await sink.close();
          } on Object {
            await sink.close().catchError((_) {});
            offset = await file.length();
            if (offset > expectedBytes) throw const LanSyncTransportException('lan_sync_local_document_size_mismatch');
            rethrow;
          }
          offset = startingOffset + responseBytes;
          if (offset > expectedBytes) throw const LanSyncTransportException('lan_sync_local_document_size_mismatch');
        } on LanSyncTransportException {
          rethrow;
        } on Object {
          if (attempt + 1 >= maximumAttempts) rethrow;
        }
      }
      if (offset != expectedBytes) throw const LanSyncTransportException('lan_sync_transfer_incomplete');
      final digest = await crypto.sha256.bind(file.openRead()).first;
      if (digest.toString() != expectedSha256) throw const LanSyncTransportException('lan_sync_local_document_hash_mismatch');
      return _LocalFileLease(file, directory);
    } on Object {
      if (await file.exists()) await file.delete();
      if (await directory.exists()) await directory.delete();
      rethrow;
    } finally {
      if (ownsClient) http.close(force: true);
    }
  }
}

final class _LocalFileLease extends Stream<List<int>> {
  _LocalFileLease(this.file, this.directory) {
    controller = StreamController<List<int>>(
      sync: true,
      onListen: _onListen,
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () async {
        await source?.cancel();
        await _cleanup();
      },
    );
  }
  final File file;
  final Directory directory;
  bool _used = false;
  bool _disposed = false;
  late final StreamController<List<int>> controller;
  StreamSubscription<List<int>>? source;
  Future<void> _onListen() async {
    if (_disposed) {
      await controller.close();
      return;
    }
    source = file.openRead().listen(
      controller.add,
      onError: (Object error, StackTrace stackTrace) async {
        await _cleanup();
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
          await controller.close();
        }
      },
      onDone: () async {
        await _cleanup();
        if (!controller.isClosed) await controller.close();
      },
    );
  }

  Future<void> _cleanup() async {
    if (_disposed) return;
    _disposed = true;
    if (await file.exists()) await file.delete();
    if (await directory.exists()) await directory.delete();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await source?.cancel();
    await _cleanup();
    if (!controller.isClosed) {
      // A single-subscription controller's close Future waits for a listener.
      // Unconsumed downloads still need immediate cancellation and reclamation.
      if (_used) {
        await controller.close();
      } else {
        unawaited(controller.close());
      }
    }
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_used) throw StateError('local_document_stream_already_listened');
    _used = true;
    return controller.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

Future<void> discardLocalDocumentStream(Stream<List<int>>? stream) async {
  if (stream is _LocalFileLease) await stream.dispose();
}

final class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
