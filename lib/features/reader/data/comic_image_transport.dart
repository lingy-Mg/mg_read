/// Shared comic image transport for shelf and transient reader sessions.
///
/// Owns bounded HTTP retries, redirects, MIME/size validation and a lazy client
/// per reader lifetime. Injected clients remain caller-owned; owned clients are
/// closed on disposal and loopback resources bypass proxies.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

typedef ComicImageFetcher = Future<Uint8List> Function(Uri uri);
typedef ComicHttpClientFactory = Future<HttpClient> Function();

ComicHttpClientFactory createProxyAwareComicHttpClientFactory(FlutterNetworkProxyManager manager) =>
    () => manager.createHttpClient(NetworkProxyTraffic.manga);

/// HTTP status failure retained for the reader's one bounded URL refresh.
final class ComicImageHttpStatusException extends HttpException {
  ComicImageHttpStatusException(this.statusCode, Uri uri) : super('Image status $statusCode.', uri: uri);

  final int statusCode;
}

/// Retries only transient transport/status failures, with bounded backoff.
/// Both saved and discovery comic readers share this transport policy.
Future<Uint8List> fetchComicImage(Uri uri, {HttpClient? client, bool Function()? isActive}) async {
  for (var attempt = 0; ; attempt++) {
    if (isActive != null && !isActive()) throw StateError('Comic image request is disposed.');
    try {
      return await _fetchComicImageAttempt(uri, client: client);
    } on Object catch (error) {
      final transient =
          error is SocketException ||
          error is TimeoutException ||
          (error is HttpException && error is! ComicImageHttpStatusException && error is! _ComicImageValidationException) ||
          (error is ComicImageHttpStatusException && const <int>{408, 500, 502, 503, 504}.contains(error.statusCode));
      if (!transient || attempt >= 2) rethrow;
      await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 250 : 750));
    }
  }
}

final class _ComicImageValidationException extends HttpException {
  _ComicImageValidationException(super.message);
}

Future<Uint8List> _fetchComicImageAttempt(Uri uri, {HttpClient? client}) async {
  const maximumBytes = 8 * 1024 * 1024;
  final ownedClient = client ?? HttpClient();
  if (client == null) {
    ownedClient
      ..maxConnectionsPerHost = 4
      ..connectionTimeout = const Duration(seconds: 15);
  }
  HttpClientRequest? activeRequest;
  HttpClientResponse? unreadResponse;
  try {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      if (current.scheme != 'http' && current.scheme != 'https') {
        throw ArgumentError.value(current, 'uri', 'Comic images require HTTP or HTTPS.');
      }
      if (client == null && _isLoopback(current)) {
        // Runtime source resources are private loopback URLs. They must never
        // be sent through a desktop proxy, which can turn a valid one-time
        // resource into an unrelated remote request.
        ownedClient.findProxy = (_) => 'DIRECT';
      }
      var openingExpired = false;
      final request = await ownedClient
          .getUrl(current)
          .then((request) {
            if (openingExpired) request.abort();
            return request;
          })
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              openingExpired = true;
              throw TimeoutException('Comic image connection timed out.');
            },
          );
      activeRequest = request;
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 20));
      unreadResponse = response;
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (redirects >= 3 || location == null) throw _ComicImageValidationException('Too many redirects.');
        unreadResponse = null;
        await response.timeout(const Duration(seconds: 20)).drain<void>();
        activeRequest = null;
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ComicImageHttpStatusException(response.statusCode, current);
      }
      final mime = response.headers.contentType?.mimeType ?? '';
      final declaredAsImage = RegExp(r'^image/[^\s/]+$', caseSensitive: false).hasMatch(mime);
      final declaredAsGenericBinary = mime.toLowerCase() == 'application/octet-stream';
      if (!declaredAsImage && !declaredAsGenericBinary) {
        throw _ComicImageValidationException('Image MIME is invalid.');
      }
      if (response.contentLength > maximumBytes) throw StateError('Image exceeds 8 MiB.');
      unreadResponse = null;
      final bytes = await response
          .timeout(const Duration(seconds: 20))
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) {
            b.add(chunk);
            if (b.length > maximumBytes) throw StateError('Image exceeds 8 MiB.');
            return b;
          })
          .then((b) => b.takeBytes());
      if (bytes.isEmpty) throw StateError('Image is empty.');
      if (declaredAsGenericBinary && !_hasKnownImageSignature(bytes)) {
        throw _ComicImageValidationException('Generic binary response is not an image.');
      }
      activeRequest = null;
      return Uint8List.fromList(bytes);
    }
  } finally {
    // Once headers arrive, HttpClientRequest.abort no longer closes the
    // response. Cancelling its body releases the pooled connection and tells
    // Runtime to abort upstream work, even if an error body never finishes.
    await unreadResponse?.listen(null).cancel();
    activeRequest?.abort();
    if (client == null) ownedClient.close(force: true);
  }
}

bool _hasKnownImageSignature(Uint8List bytes) {
  bool startsWith(List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var index = 0; index < signature.length; index += 1) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  if (startsWith(<int>[0xff, 0xd8, 0xff]) ||
      startsWith(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ||
      startsWith(<int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      startsWith(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) ||
      startsWith(<int>[0x42, 0x4d])) {
    return true;
  }
  if (bytes.length < 12 || !startsWith(<int>[0x52, 0x49, 0x46, 0x46])) return false;
  return bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50;
}

Future<HttpClient> _createSystemComicHttpClient() => FlutterNetworkProxyManager().createHttpClient(NetworkProxyTraffic.manga);

ComicImageHttpClientOwner createComicImageHttpClientOwner(ComicHttpClientFactory? factory) =>
    ComicImageHttpClientOwner(factory ?? _createSystemComicHttpClient);

/// Shared bounded-refresh classification; callers enforce the single retry.
/// Uses the resource's lifetime contract instead of interpreting engine URLs.
bool shouldRefreshComicResourceAfterFailure(Object error, {required bool regenerable}) {
  if (error is ComicImageHttpStatusException) {
    return error.statusCode == HttpStatus.unauthorized ||
        error.statusCode == HttpStatus.forbidden ||
        (regenerable && (error.statusCode == HttpStatus.notFound || error.statusCode == HttpStatus.gone));
  }
  return regenerable && error is SocketException;
}

/// Owns one lazy HTTP client for a single reader data-source lifetime.
final class ComicImageHttpClientOwner {
  ComicImageHttpClientOwner(this._factory);

  final ComicHttpClientFactory _factory;
  final Set<Future<void>> _loads = <Future<void>>{};
  HttpClient? _client;
  Future<HttpClient>? _clientLoading;
  bool _disposed = false;

  Future<Uint8List> fetch(Uri uri) {
    if (_disposed) return Future<Uint8List>.error(StateError('Comic image HTTP client is disposed.'));
    final task = _fetch(uri);
    late final Future<void> tracked;
    tracked = task.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() => _loads.remove(tracked));
    _loads.add(tracked);
    return task;
  }

  Future<Uint8List> _fetch(Uri uri) async => fetchComicImage(uri, client: await _ensureClient(), isActive: () => !_disposed);

  Future<HttpClient> _ensureClient() async {
    if (_disposed) throw StateError('Comic image HTTP client is disposed.');
    final current = _client;
    if (current != null) return current;
    final active = _clientLoading;
    if (active != null) return active;
    final task = _initializeClient();
    _clientLoading = task;
    try {
      return await task;
    } finally {
      if (identical(_clientLoading, task)) _clientLoading = null;
    }
  }

  Future<HttpClient> _initializeClient() async {
    final created = await _factory();
    if (_disposed) {
      created.close(force: true);
      throw StateError('Comic image HTTP client is disposed.');
    }
    created
      ..maxConnectionsPerHost = 4
      ..connectionTimeout = const Duration(seconds: 15);
    return _client = created;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _client?.close(force: true);
    final loading = _clientLoading;
    if (loading != null) {
      try {
        (await loading).close(force: true);
      } on Object {
        // A failed client factory has already completed its caller-facing
        // request. Disposal remains best-effort and never leaks that error.
      }
    }
    if (_loads.isNotEmpty) await Future.wait<void>(_loads.toList(growable: false));
  }
}

bool _isLoopback(Uri uri) => uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
