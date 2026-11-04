/// Cross-process HTTP coordinator and byte-range media server for native
/// companion acceptance. It reports a real companion receiver port and state;
/// only the source catalog is deterministic test metadata.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

final class CompanionNativeQaServer {
  CompanionNativeQaServer._({required this.server, required this.sample});

  static const coordinatorPort = 41079;
  final HttpServer server;
  final File sample;
  Map<String, Object?>? _ready;
  Map<String, Object?>? _externalState;
  Map<String, Object?>? _completion;
  Map<String, Object?> Function()? _stateReader;
  final Completer<Map<String, Object?>> _done = Completer<Map<String, Object?>>();

  static Future<CompanionNativeQaServer> start({String bindAddress = '0.0.0.0', int port = coordinatorPort}) async {
    final path = const String.fromEnvironment('MGREAD_COMPANION_SAMPLE_PATH');
    if (path.isEmpty) throw StateError('MGREAD_COMPANION_SAMPLE_PATH is required.');
    final sample = File(path);
    if (!await sample.exists() || await sample.length() < 4096) {
      throw StateError('Native companion sample is missing or too small: $path');
    }
    final server = await HttpServer.bind(InternetAddress(bindAddress), port, shared: true);
    final qa = CompanionNativeQaServer._(server: server, sample: sample);
    server.listen(qa._handle);
    return qa;
  }

  void publishReady({required String deviceId, required String label, required int receiverPort}) {
    _ready = {'id': deviceId, 'label': label, 'port': receiverPort};
  }

  void setStateReader(Map<String, Object?> Function() reader) => _stateReader = reader;

  Future<Map<String, Object?>> get done => _done.future.timeout(const Duration(minutes: 8));

  Future<void> writeReport(Map<String, Object?> report) async {
    final path = const String.fromEnvironment('MGREAD_COMPANION_QA_REPORT_PATH');
    if (path.isEmpty) return;
    final output = File(path);
    await output.parent.create(recursive: true);
    await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n', flush: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      switch (request.uri.path) {
        case '/ready':
          final ready = _ready;
          if (ready == null) {
            request.response.statusCode = HttpStatus.serviceUnavailable;
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode(ready));
          }
          await request.response.close();
        case '/state':
          final state = _stateReader?.call() ?? _externalState;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(state ?? {'status': 'waiting'}));
          await request.response.close();
        case '/receiver-ready':
          _ready = await _readPost(request);
          request.response.statusCode = HttpStatus.accepted;
          await request.response.close();
        case '/receiver-state':
          _externalState = await _readPost(request);
          request.response.statusCode = HttpStatus.accepted;
          await request.response.close();
        case '/completion':
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'done': _completion != null, 'report': _completion}));
          await request.response.close();
        case '/done':
          if (request.method != 'POST') {
            request.response.statusCode = HttpStatus.methodNotAllowed;
            await request.response.close();
            return;
          }
          final payload = jsonDecode(await utf8.decoder.bind(request).join());
          if (payload is! Map<String, dynamic>) {
            request.response.statusCode = HttpStatus.badRequest;
            await request.response.close();
            return;
          }
          if (_done.isCompleted) {
            request.response.statusCode = HttpStatus.conflict;
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.accepted;
          await request.response.close();
          _completion = Map<String, Object?>.from(payload);
          await writeReport(_completion!);
          _done.complete(Map<String, Object?>.from(payload));
        case '/media.mp4':
          await _serveMedia(request);
        default:
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
      }
    } on Object catch (error) {
      await request.response.close().catchError((Object _) {});
      stderr.writeln('COMPANION_QA_HTTP_ERROR ${error.runtimeType}');
    }
  }

  Future<Map<String, Object?>> _readPost(HttpRequest request) async {
    if (request.method != 'POST') throw const HttpException('POST required');
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > 64 * 1024) throw const HttpException('QA report too large');
      bytes.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) throw const FormatException('Expected QA JSON object');
    return Map<String, Object?>.from(value);
  }

  Future<void> _serveMedia(HttpRequest request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final length = await sample.length();
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    var start = 0;
    var end = length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
        await _rangeNotSatisfiable(request, length);
        return;
      }
      if (match[1]!.isEmpty) {
        final suffix = int.tryParse(match[2]!);
        if (suffix == null || suffix <= 0) {
          await _rangeNotSatisfiable(request, length);
          return;
        }
        start = (length - suffix).clamp(0, length);
      } else {
        start = int.tryParse(match[1]!) ?? length;
        end = match[2]!.isEmpty ? length - 1 : (int.tryParse(match[2]!) ?? -1);
      }
      if (start >= length || end < start) {
        await _rangeNotSatisfiable(request, length);
        return;
      }
      end = end.clamp(0, length - 1);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
    } else {
      request.response.statusCode = HttpStatus.ok;
    }
    final count = end - start + 1;
    request.response.contentLength = count;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await request.response.addStream(sample.openRead(start, end + 1));
    await request.response.close();
  }

  Future<void> _rangeNotSatisfiable(HttpRequest request, int length) async {
    request.response
      ..statusCode = HttpStatus.requestedRangeNotSatisfiable
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}
