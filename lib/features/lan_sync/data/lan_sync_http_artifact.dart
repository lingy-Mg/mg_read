/// 局域网同步的标准 HTTP 制品传输边界。
///
/// 职责：固定单次传输的制品版本并提供 RFC 9110 单范围响应；客户端使用
/// ETag/If-Range 从临时文件续传，完成大小与 SHA-256 校验后才交给安装层。
///
/// 注意：本层不拥有 Runtime；调用方只应传入已经固定的制品流。所有临时文件
/// 在成功、失败或取消时由会话所有者关闭并删除。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

const String lanSyncHttpProtocol = 'mgread-http/1';

/// 配对密钥只用于请求认证；请求体仍由标准 HTTP 直接承载。
final class LanSyncHttpAuthentication {
  const LanSyncHttpAuthentication._();

  static const String deviceHeader = 'x-mgread-device';
  static const String timestampHeader = 'x-mgread-timestamp';
  static const String nonceHeader = 'x-mgread-nonce';
  static const String contentHashHeader = 'x-mgread-content-sha256';
  static const String authorizationHeader = 'authorization';

  static void sign(
    HttpClientRequest request, {
    required String deviceId,
    required List<int> sharedSecret,
    required String contentSha256,
    DateTime? now,
    String? nonce,
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch ~/ 1000;
    final requestNonce = nonce ?? _nonce();
    final path = request.uri.path + (request.uri.hasQuery ? '?${request.uri.query}' : '');
    final signature = _signature(
      sharedSecret,
      method: request.method,
      path: path,
      deviceId: deviceId,
      timestamp: timestamp,
      nonce: requestNonce,
      contentSha256: contentSha256,
    );
    request.headers
      ..set(deviceHeader, deviceId)
      ..set(timestampHeader, timestamp.toString())
      ..set(nonceHeader, requestNonce)
      ..set(contentHashHeader, contentSha256)
      ..set(authorizationHeader, 'MgRead-HMAC-SHA256 $signature');
  }

  static bool verify(HttpRequest request, {required List<int> sharedSecret, DateTime? now, Map<String, int>? acceptedNonces}) {
    final deviceId = request.headers.value(deviceHeader);
    final timestamp = int.tryParse(request.headers.value(timestampHeader) ?? '');
    final nonce = request.headers.value(nonceHeader);
    final contentHash = request.headers.value(contentHashHeader);
    final authorization = request.headers.value(authorizationHeader);
    if (deviceId == null ||
        timestamp == null ||
        nonce == null ||
        nonce.length < 20 ||
        contentHash == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(contentHash) ||
        authorization == null ||
        !authorization.startsWith('MgRead-HMAC-SHA256 ')) {
      return false;
    }
    final current = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch ~/ 1000;
    if ((current - timestamp).abs() > 120) return false;
    final path = request.uri.path + (request.uri.hasQuery ? '?${request.uri.query}' : '');
    final expected = _signature(
      sharedSecret,
      method: request.method,
      path: path,
      deviceId: deviceId,
      timestamp: timestamp,
      nonce: nonce,
      contentSha256: contentHash,
    );
    final actual = authorization.substring('MgRead-HMAC-SHA256 '.length);
    if (!_constantTimeEquals(expected, actual)) return false;
    if (acceptedNonces != null) {
      acceptedNonces.removeWhere((_, seenAt) => current - seenAt > 120);
      if (acceptedNonces.containsKey(nonce)) return false;
      acceptedNonces[nonce] = current;
    }
    return true;
  }

  static String bodyHash(List<int> bytes) => sha256.convert(bytes).toString();

  static String _signature(
    List<int> secret, {
    required String method,
    required String path,
    required String deviceId,
    required int timestamp,
    required String nonce,
    required String contentSha256,
  }) {
    final canonical = '$method\n$path\n$deviceId\n$timestamp\n$nonce\n$contentSha256';
    return base64Url.encode(Hmac(sha256, secret).convert(utf8.encode(canonical)).bytes).replaceAll('=', '');
  }

  static String _nonce() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(18, (_) => random.nextInt(256))).replaceAll('=', '');
  }
}

bool _constantTimeEquals(String left, String right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}

final class LanSyncHttpArtifact {
  LanSyncHttpArtifact._(this.descriptor, this._file);

  final LanSyncPluginDescriptor descriptor;
  final File _file;
  bool _closed = false;

  static Future<LanSyncHttpArtifact> materialize(
    LanSyncPluginDescriptor descriptor,
    Stream<List<int>> bytes, {
    Directory? temporaryDirectory,
  }) async {
    final directory = temporaryDirectory ?? await Directory.systemTemp.createTemp('mgread-lan-http-');
    final ownsDirectory = temporaryDirectory == null;
    final file = File('${directory.path}${Platform.pathSeparator}artifact.bin');
    final sink = file.openWrite();
    final hashSink = _Sha256Sink();
    var written = 0;
    try {
      await for (final chunk in bytes) {
        written += chunk.length;
        if (written > descriptor.bytes) {
          throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
        }
        hashSink.add(chunk);
        sink.add(chunk);
      }
      await sink.close();
      final digest = await hashSink.close();
      if (written != descriptor.bytes || digest != descriptor.sha256) {
        throw const LanSyncTransportException('lan_sync_plugin_hash_mismatch');
      }
      return LanSyncHttpArtifact._(descriptor, file);
    } on Object {
      await sink.close().catchError((_) {});
      if (await file.exists()) await file.delete();
      if (ownsDirectory && await directory.exists()) await directory.delete();
      rethrow;
    }
  }

  String get etag => '"sha256-${descriptor.sha256}"';

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
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    final range = rangeHeader == null || (ifRange != null && ifRange != etag) ? null : _parseSingleRange(rangeHeader, descriptor.bytes);
    if (rangeHeader != null && ifRange != null && ifRange != etag) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = descriptor.bytes;
    } else if (rangeHeader != null && range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${descriptor.bytes}');
      response.contentLength = 0;
      await response.close();
      return;
    } else if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.start}-${range.end}/${descriptor.bytes}');
      response.contentLength = range.length;
    } else {
      response.statusCode = HttpStatus.ok;
      response.contentLength = descriptor.bytes;
    }
    if (request.method == 'GET') {
      final start = range?.start ?? 0;
      final end = range?.end ?? descriptor.bytes - 1;
      await response.addStream(_file.openRead(start, end + 1));
    }
    await response.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final directory = _file.parent;
    if (await _file.exists()) await _file.delete();
    if (await directory.exists() && directory.path.contains('mgread-lan-http-')) {
      await directory.delete();
    }
  }
}

final class LanSyncHttpArtifactClient {
  const LanSyncHttpArtifactClient({this.maximumAttempts = 4});

  final int maximumAttempts;

  Future<Stream<List<int>>> download(
    Uri uri,
    LanSyncPluginDescriptor descriptor, {
    HttpClient? client,
    void Function(HttpClientRequest request, String contentSha256)? authenticate,
  }) async {
    final ownedClient = client == null;
    final http = client ?? HttpClient();
    final directory = await Directory.systemTemp.createTemp('mgread-lan-http-receive-');
    final file = File('${directory.path}${Platform.pathSeparator}artifact.part');
    var offset = 0;
    String? etag;
    try {
      for (var attempt = 0; attempt < maximumAttempts && offset < descriptor.bytes; attempt++) {
        try {
          final request = await http.getUrl(uri);
          authenticate?.call(request, LanSyncHttpAuthentication.bodyHash(const <int>[]));
          if (offset > 0) {
            request.headers
              ..set(HttpHeaders.rangeHeader, 'bytes=$offset-')
              ..set(HttpHeaders.ifRangeHeader, etag!);
          }
          final response = await request.close();
          if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
            offset = 0;
            etag = null;
            await file.writeAsBytes(const <int>[]);
            continue;
          }
          if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
            throw LanSyncTransportException('lan_sync_http_failed', reason: 'status_${response.statusCode}');
          }
          final responseEtag = response.headers.value(HttpHeaders.etagHeader);
          if (responseEtag == null || responseEtag != '"sha256-${descriptor.sha256}"') {
            throw const LanSyncTransportException('lan_sync_plugin_version_changed');
          }
          if (offset > 0 && response.statusCode == HttpStatus.ok) {
            offset = 0;
            await file.writeAsBytes(const <int>[]);
          }
          etag = responseEtag;
          final sink = file.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
          await sink.addStream(response);
          await sink.close();
          offset = await file.length();
          if (offset > descriptor.bytes) {
            throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
          }
        } on LanSyncTransportException {
          rethrow;
        } on Object {
          if (attempt + 1 >= maximumAttempts) rethrow;
        }
      }
      if (offset != descriptor.bytes) throw const LanSyncTransportException('lan_sync_transfer_incomplete');
      final digest = await _sha256File(file);
      if (digest != descriptor.sha256) throw const LanSyncTransportException('lan_sync_plugin_hash_mismatch');
      return _DeletingFileStream(file, directory);
    } on Object {
      if (await file.exists()) await file.delete();
      if (await directory.exists()) await directory.delete();
      rethrow;
    } finally {
      if (ownedClient) http.close(force: true);
    }
  }
}

final class _ByteRange {
  const _ByteRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
}

_ByteRange? _parseSingleRange(String value, int length) {
  if (length <= 0 || !value.startsWith('bytes=') || value.substring(6).contains(',')) return null;
  final match = RegExp(r'^(\d*)-(\d*)$').firstMatch(value.substring(6));
  if (match == null) return null;
  final first = match.group(1)!;
  final second = match.group(2)!;
  if (first.isEmpty) {
    final suffix = int.tryParse(second);
    if (suffix == null || suffix <= 0) return null;
    return _ByteRange(length - suffix.clamp(1, length), length - 1);
  }
  final start = int.tryParse(first);
  if (start == null || start >= length) return null;
  final requestedEnd = second.isEmpty ? length - 1 : int.tryParse(second);
  if (requestedEnd == null || requestedEnd < start) return null;
  return _ByteRange(start, requestedEnd.clamp(start, length - 1));
}

final class _Sha256Sink {
  final _DigestSink _output = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_output);

  void add(List<int> bytes) => _input.add(bytes);

  Future<String> close() async {
    _input.close();
    return _output.value!.toString();
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Future<String> _sha256File(File file) async {
  final sink = _Sha256Sink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  return sink.close();
}

final class _DeletingFileStream extends Stream<List<int>> {
  _DeletingFileStream(this._file, this._directory);
  final File _file;
  final Directory _directory;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    late StreamSubscription<List<int>> subscription;
    Future<void> cleanup() async {
      if (await _file.exists()) await _file.delete();
      if (await _directory.exists()) await _directory.delete();
    }

    subscription = _file.openRead().listen(
      onData,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(cleanup());
        if (onError != null) Function.apply(onError, <Object?>[error, stackTrace]);
      },
      onDone: () {
        unawaited(cleanup().whenComplete(() => onDone?.call()));
      },
      cancelOnError: cancelOnError,
    );
    return _CleanupSubscription(subscription, cleanup);
  }
}

final class _CleanupSubscription<T> implements StreamSubscription<T> {
  _CleanupSubscription(this._delegate, this._cleanup);
  final StreamSubscription<T> _delegate;
  final Future<void> Function() _cleanup;
  @override
  Future<void> cancel() async {
    await _delegate.cancel();
    await _cleanup();
  }

  @override
  void onData(void Function(T data)? handleData) => _delegate.onData(handleData);
  @override
  void onError(Function? handleError) => _delegate.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);
  @override
  void resume() => _delegate.resume();
  @override
  bool get isPaused => _delegate.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture(futureValue);
}
