/// Streams resolved video resources into an app-owned file. Temporary files
/// stay in the caller's cache directory and are removed before this job ends.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class SourceVideoTransferResult {
  const SourceVideoTransferResult({required this.file, required this.extension, required this.mimeType});

  final File file;
  final String extension;
  final String mimeType;
}

final class SourceVideoTransferException implements Exception {
  const SourceVideoTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Uses one HTTP client per transfer. Completing [cancellation] closes that
/// client and aborts all requests owned by the transfer.
Future<SourceVideoTransferResult> downloadSourceVideo({
  required Uri uri,
  required Map<String, String> headers,
  required Directory directory,
  required void Function(int received, int? total) onProgress,
  Future<void>? cancellation,
  Future<HttpClient> Function()? createClient,
}) async {
  final client = await (createClient?.call() ?? Future.value(HttpClient()));
  final transfer = _VideoTransfer(client, uri, headers, onProgress);
  if (cancellation != null) unawaited(cancellation.then((_) => transfer.cancel()));
  try {
    client
      ..connectionTimeout = _networkTimeout
      ..maxConnectionsPerHost = _concurrency
      ..autoUncompress = false;
    await directory.create(recursive: true);
    final temporary = await directory.createTemp('transfer-');
    try {
      return await transfer.download(temporary, directory);
    } finally {
      try {
        await temporary.delete(recursive: true);
      } on FileSystemException {
        // Cache cleanup can retry if another process temporarily holds a file.
      }
    }
  } finally {
    client.close(force: true);
  }
}

const _networkTimeout = Duration(seconds: 30);
const _concurrency = 6;
const _maximumManifestBytes = 2 * 1024 * 1024;
const _maximumSegments = 20000;
typedef _VideoFormat = ({String extension, String mime});
typedef _ByteRange = ({int start, int length});
typedef _MediaPart = ({Uri uri, _ByteRange? range});

const _formats = <String, _VideoFormat>{
  'mp4': (extension: 'mp4', mime: 'video/mp4'),
  'm4v': (extension: 'm4v', mime: 'video/x-m4v'),
  'mov': (extension: 'mov', mime: 'video/quicktime'),
  'mkv': (extension: 'mkv', mime: 'video/x-matroska'),
  'webm': (extension: 'webm', mime: 'video/webm'),
  'avi': (extension: 'avi', mime: 'video/x-msvideo'),
  'flv': (extension: 'flv', mime: 'video/x-flv'),
  'ts': (extension: 'ts', mime: 'video/mp2t'),
  'mpeg': (extension: 'mpeg', mime: 'video/mpeg'),
  'ogv': (extension: 'ogv', mime: 'video/ogg'),
  'wmv': (extension: 'wmv', mime: 'video/x-ms-wmv'),
  '3gp': (extension: '3gp', mime: 'video/3gpp'),
};

final class _VideoTransfer {
  _VideoTransfer(this.client, this.uri, this.headers, this.onProgress);

  final HttpClient client;
  final Uri uri;
  final Map<String, String> headers;
  final void Function(int, int?) onProgress;
  final Stopwatch _progressClock = Stopwatch()..start();
  bool _cancelled = false;
  int _received = 0;
  int? _total;

  void cancel() {
    _cancelled = true;
    client.close(force: true);
  }

  Future<SourceVideoTransferResult> download(Directory temporary, Directory destination) async {
    final source = await _open(uri);
    final output = _file(temporary, 'video');
    late final _VideoFormat format;
    try {
      if (source.isHls) {
        format = await _downloadHls(source, temporary, output);
      } else {
        format = source.videoFormat ?? (throw const SourceVideoTransferException('暂不支持此视频格式。'));
        _total = source.length;
        onProgress(0, _total);
        await _save(source, output);
      }
    } finally {
      await source.close();
    }
    _checkCancelled();
    final length = await output.length();
    onProgress(length, length);
    final file = await output.rename(_file(destination, 'video.${format.extension}').path);
    return SourceVideoTransferResult(file: file, extension: format.extension, mimeType: format.mime);
  }

  Future<_VideoFormat> _downloadHls(_VideoResponse source, Directory temporary, File output) async {
    var current = source;
    try {
      for (var depth = 0; depth < 4; depth++) {
        final manifest = await current.readManifest();
        final variant = _selectVariant(manifest, current.uri);
        if (variant == null) {
          final media = _parseMedia(manifest, current.uri);
          onProgress(0, null);
          await _savePlaylist(media, temporary, output);
          return _formats[media.initialization == null ? 'ts' : 'mp4']!;
        }
        await current.close();
        current = await _open(variant);
      }
      throw const SourceVideoTransferException('播放列表嵌套层数过多。');
    } finally {
      await current.close();
    }
  }

  Future<void> _savePlaylist(_MediaPlaylist media, Directory temporary, File output) async {
    final writer = await output.open(mode: FileMode.write);
    try {
      final initialization = media.initialization;
      if (initialization != null) {
        final file = _file(temporary, 'init');
        await _downloadPart(initialization, file, _PartFormat.init);
        await _appendAndDelete(file, writer);
      }
      final format = initialization == null ? _PartFormat.transport : _PartFormat.fragment;
      // Keep a bounded window of segments on disk, including when an early
      // segment downloads slowly. Playback order stays independent of arrival.
      for (var start = 0; start < media.parts.length; start += _concurrency) {
        final end = (start + _concurrency).clamp(0, media.parts.length);
        final files = await Future.wait([
          for (var index = start; index < end; index++) _downloadPart(media.parts[index], _file(temporary, 'segment-$index'), format),
        ]);
        for (final file in files) {
          await _appendAndDelete(file, writer);
        }
      }
    } finally {
      await writer.close();
    }
  }

  Future<File> _downloadPart(_MediaPart part, File to, _PartFormat format) async {
    try {
      final source = await _open(part.uri, range: part.range);
      try {
        if (!format.matches(source.prefix)) throw const SourceVideoTransferException('播放列表包含不支持的视频分片。');
        await _save(source, to);
        return to;
      } finally {
        await source.close();
      }
    } on Object {
      // Unblock sibling HTTP requests so a failed segment does not leave the
      // transfer waiting on a stalled or very large download in the window.
      client.close(force: true);
      rethrow;
    }
  }

  Future<void> _appendAndDelete(File file, RandomAccessFile output) async {
    await for (final bytes in file.openRead()) {
      _checkCancelled();
      await output.writeFrom(bytes);
    }
    await file.delete();
  }

  Future<void> _save(_VideoResponse source, File file) async {
    final writer = await file.open(mode: FileMode.write);
    var bytes = 0;
    try {
      await for (final chunk in source.body()) {
        _checkCancelled();
        await writer.writeFrom(chunk);
        bytes += chunk.length;
        _received += chunk.length;
        if (_progressClock.elapsedMilliseconds >= 125) {
          onProgress(_received, _total);
          _progressClock.reset();
        }
      }
      final length = source.length;
      if (bytes == 0 || (length != null && bytes != length)) throw const SourceVideoTransferException('视频文件下载不完整。');
    } finally {
      await writer.close();
    }
  }

  Future<_VideoResponse> _open(Uri target, {_ByteRange? range}) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      _checkCancelled();
      if (!(target.isScheme('http') || target.isScheme('https')) || target.host.isEmpty || target.userInfo.isNotEmpty) {
        throw const SourceVideoTransferException('视频下载地址无效。');
      }
      final request = await client.getUrl(target).timeout(_networkTimeout);
      request.followRedirects = false;
      // Credentials supplied for the resolved media URL are origin scoped.
      if (target.origin == uri.origin) {
        for (final MapEntry(:key, :value) in headers.entries) {
          if (!_controlledHeaders.contains(key.toLowerCase())) request.headers.set(key, value);
        }
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, 'bytes=${range.start}-${range.start + range.length - 1}');
      final response = await request.close().timeout(_networkTimeout);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen(null).cancel();
        if (location == null) throw const SourceVideoTransferException('视频下载重定向地址无效。');
        target = target.resolve(location);
        continue;
      }
      final valid = range == null
          ? response.statusCode == HttpStatus.ok
          : response.statusCode == HttpStatus.partialContent && _matchesRange(response, range);
      if (!valid) {
        await response.listen(null).cancel();
        throw SourceVideoTransferException('视频下载请求失败（HTTP ${response.statusCode}）。');
      }
      return _VideoResponse.open(target, response, range: range);
    }
    throw const SourceVideoTransferException('视频下载重定向次数过多。');
  }

  void _checkCancelled() {
    if (_cancelled) throw StateError('视频下载已取消。');
  }
}

const _controlledHeaders = {
  HttpHeaders.acceptEncodingHeader,
  HttpHeaders.connectionHeader,
  HttpHeaders.contentLengthHeader,
  HttpHeaders.hostHeader,
  HttpHeaders.rangeHeader,
  HttpHeaders.transferEncodingHeader,
};

bool _matchesRange(HttpClientResponse response, _ByteRange range) {
  final header = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(header);
  return match != null && int.tryParse(match[1]!) == range.start && int.tryParse(match[2]!) == range.start + range.length - 1;
}

File _file(Directory directory, String name) => File('${directory.path}${Platform.pathSeparator}$name');

final class _VideoResponse {
  _VideoResponse(this.uri, this.mime, this.length, this.prefix, this._chunks, this._stream);

  final Uri uri;
  final String? mime;
  final int? length;
  final Uint8List prefix;
  final List<List<int>> _chunks;
  final StreamIterator<List<int>> _stream;

  static Future<_VideoResponse> open(Uri uri, HttpClientResponse response, {required _ByteRange? range}) async {
    final iterator = StreamIterator(response.timeout(_networkTimeout));
    try {
      final chunks = <List<int>>[];
      final prefix = BytesBuilder();
      while (prefix.length < 16 && await iterator.moveNext()) {
        final chunk = iterator.current;
        chunks.add(chunk);
        prefix.add(chunk.take(16 - prefix.length).toList(growable: false));
      }
      final length = range?.length ?? (response.contentLength < 0 ? null : response.contentLength);
      return _VideoResponse(uri, response.headers.contentType?.mimeType, length, prefix.takeBytes(), chunks, iterator);
    } on Object {
      await iterator.cancel();
      rethrow;
    }
  }

  bool get isHls =>
      _startsWith(prefix, '#EXTM3U') ||
      _startsWith(prefix, '#EXTM3U', offset: 3) ||
      mime == 'application/vnd.apple.mpegurl' ||
      mime == 'application/x-mpegurl' ||
      mime == 'audio/mpegurl' ||
      uri.path.toLowerCase().endsWith('.m3u8');

  _VideoFormat? get videoFormat {
    if (mime == 'text/html' || mime == 'application/json' || mime == 'application/xml' || mime == 'text/xml') return null;
    final named = _formats[uri.path.split('.').last.toLowerCase()];
    final declared = _formats.values.where((value) => value.mime == mime).firstOrNull;
    if (_startsWith(prefix, 'ftyp', offset: 4)) {
      if (_startsWith(prefix, 'qt  ', offset: 8)) return _formats['mov'];
      if (_startsWith(prefix, '3gp', offset: 8)) return _formats['3gp'];
      return _formats['mp4'];
    }
    if (_startsWith(prefix, 'FLV')) return _formats['flv'];
    if (_startsWith(prefix, 'RIFF') && _startsWith(prefix, 'AVI ', offset: 8)) return _formats['avi'];
    if (prefix.length >= 4 && prefix[0] == 0x1a && prefix[1] == 0x45 && prefix[2] == 0xdf && prefix[3] == 0xa3) {
      return declared ?? named ?? _formats['mkv'];
    }
    if (_PartFormat.transport.matches(prefix)) return _formats['ts'];
    return declared ?? named;
  }

  Stream<List<int>> body() async* {
    yield* Stream.fromIterable(_chunks);
    while (await _stream.moveNext()) {
      yield _stream.current;
    }
  }

  Future<List<String>> readManifest() async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body()) {
      if (bytes.length + chunk.length > _maximumManifestBytes) throw const SourceVideoTransferException('视频播放列表过大。');
      bytes.add(chunk);
    }
    final lines = const LineSplitter().convert(utf8.decode(bytes.takeBytes())).map((line) => line.trim()).toList();
    if (lines.firstOrNull != '#EXTM3U') throw const SourceVideoTransferException('视频播放列表无效。');
    return lines;
  }

  Future<void> close() => _stream.cancel();
}

bool _startsWith(List<int> bytes, String text, {int offset = 0}) {
  if (bytes.length < offset + text.length) return false;
  for (var index = 0; index < text.length; index++) {
    if (bytes[offset + index] != text.codeUnitAt(index)) return false;
  }
  return true;
}

Uri? _selectVariant(List<String> lines, Uri base) {
  final outOfBand = <(String, String)>{};
  for (final line in lines.where((line) => line.startsWith('#EXT-X-MEDIA:'))) {
    final attributes = _attributes(line);
    final type = attributes['TYPE'];
    final id = attributes['GROUP-ID'];
    if (type != null && id != null && attributes.containsKey('URI')) outOfBand.add((type, id));
  }
  var hasVariants = false;
  var peakBandwidth = -1;
  Uri? selected;
  for (var index = 0; index + 1 < lines.length; index++) {
    final line = lines[index];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    hasVariants = true;
    final attributes = _attributes(line);
    final location = lines[index + 1];
    if (location.isEmpty || location.startsWith('#')) continue;
    if (outOfBand.contains(('AUDIO', attributes['AUDIO'])) || outOfBand.contains(('VIDEO', attributes['VIDEO']))) continue;
    final bandwidth = int.tryParse(attributes['BANDWIDTH'] ?? '') ?? 0;
    if (bandwidth <= peakBandwidth) continue;
    selected = base.resolve(location);
    peakBandwidth = bandwidth;
  }
  if (hasVariants && selected == null) throw const SourceVideoTransferException('该播放列表的音视频为分离轨道，暂不支持缓存。');
  return selected;
}

typedef _MediaPlaylist = ({_MediaPart? initialization, List<_MediaPart> parts});

_MediaPlaylist _parseMedia(List<String> lines, Uri base) {
  if (!lines.contains('#EXT-X-ENDLIST')) throw const SourceVideoTransferException('直播或未结束的播放列表无法缓存。');
  final parts = <_MediaPart>[];
  _MediaPart? initialization;
  String? pendingRange;
  var discontinuity = false;
  for (final line in lines) {
    if (line.startsWith('#EXT-X-KEY:') && _attributes(line)['METHOD'] != 'NONE') {
      throw const SourceVideoTransferException('暂不支持加密的播放列表。');
    }
    if (line == '#EXT-X-I-FRAMES-ONLY' || line == '#EXT-X-GAP') throw const SourceVideoTransferException('播放列表的视频分片不完整。');
    if (line == '#EXT-X-DISCONTINUITY') discontinuity = true;
    if (line.startsWith('#EXT-X-MAP:')) {
      final attributes = _attributes(line);
      final location = attributes['URI'];
      if (location == null || location.isEmpty) throw const SourceVideoTransferException('视频初始化分片无效。');
      final range = attributes['BYTERANGE'];
      final part = (uri: base.resolve(location), range: range == null ? null : _byteRange(range, implicitStart: 0));
      if ((initialization == null && parts.isNotEmpty) || (initialization != null && initialization != part)) {
        throw const SourceVideoTransferException('暂不支持切换初始化分片的播放列表。');
      }
      initialization = part;
    } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
      pendingRange = line.substring('#EXT-X-BYTERANGE:'.length);
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      final target = base.resolve(line);
      final previous = parts.lastOrNull;
      final previousRange = previous?.range;
      final start = previous?.uri == target && previousRange != null ? previousRange.start + previousRange.length : null;
      parts.add((uri: target, range: pendingRange == null ? null : _byteRange(pendingRange, implicitStart: start)));
      pendingRange = null;
      if (parts.length > _maximumSegments) throw const SourceVideoTransferException('视频分片数量过多。');
    }
  }
  if (parts.isEmpty || pendingRange != null) throw const SourceVideoTransferException('视频播放列表无效。');
  if (initialization != null && discontinuity) throw const SourceVideoTransferException('暂不支持时间线不连续的 MP4 播放列表。');
  return (initialization: initialization, parts: parts);
}

Map<String, String> _attributes(String line) => {
  for (final match in RegExp(r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]+))').allMatches(line.substring(line.indexOf(':') + 1)))
    match[1]!: match[2] ?? match[3]!,
};

_ByteRange _byteRange(String text, {required int? implicitStart}) {
  final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(text);
  if (match == null) throw const SourceVideoTransferException('视频分片的字节范围无效。');
  final length = int.tryParse(match[1]!);
  final start = match[2] == null ? implicitStart : int.tryParse(match[2]!);
  if (length == null || length <= 0 || start == null || start + length < start) {
    throw const SourceVideoTransferException('视频分片的字节范围无效。');
  }
  return (start: start, length: length);
}

enum _PartFormat {
  init,
  fragment,
  transport;

  bool matches(List<int> prefix) => switch (this) {
    init => _startsWith(prefix, 'ftyp', offset: 4) || _startsWith(prefix, 'moov', offset: 4),
    fragment => ['styp', 'moof', 'sidx', 'emsg', 'prft'].any((box) => _startsWith(prefix, box, offset: 4)),
    transport => prefix.length >= 4 && prefix.first == 0x47 && (prefix[3] & 0x30) != 0,
  };
}
