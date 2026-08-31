/// 应用共享的数据源封面缓存适配器。
///
/// 职责：
/// - 读取和写入 Content Library 所有的封面缓存。
/// - 在缓存缺失时获取远端封面，并迁移旧书架封面对象。
/// - 同一封面下载 single-flight，并通过一个有界、可轮换的 HttpClient
///   复用 TCP/TLS 连接。
///
/// 注意：
/// - 此适配器只返回显示字节，不向页面暴露文件路径或网络响应。
/// - 调用方必须异步消费结果，封面失败不得阻塞书籍主体内容。
/// - client 由本适配器所有；外部注入的 fetcher 仍由调用方所有。
/// - 代理配置键变化时只轮换后续请求使用的 client；dispose 会强制收敛
///   本适配器拥有的活动连接，之后的新调用明确失败。
///
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// 搜索、发现、详情、书架、播放器和数据源图标共用的封面解析实现。
final class ContentLibrarySourceCoverPersistence implements BookCoverBytesLoader {
  ContentLibrarySourceCoverPersistence(
    this._library, {
    SourceCoverFetcher? fetcher,
    SourceCoverHttpClientFactory? clientFactory,
    SourceCoverHttpClientConfigurationKey? clientConfigurationKey,
    DateTime Function()? clock,
  }) : assert(fetcher == null || clientFactory == null),
       _externalFetcher = fetcher,
       _httpClientOwner = fetcher == null
           ? SourceCoverHttpClientOwner(clientFactory ?? _createSystemHttpClient, configurationKey: clientConfigurationKey)
           : null,
       _clock = clock ?? DateTime.now;

  static const Duration _negativeCacheDuration = Duration(seconds: 30);
  static const int _maximumNegativeEntries = 128;

  final ContentLibrary _library;
  final SourceCoverFetcher? _externalFetcher;
  final SourceCoverHttpClientOwner? _httpClientOwner;
  final DateTime Function() _clock;
  final Map<String, Future<List<int>?>> _remoteLoads = <String, Future<List<int>?>>{};
  final LinkedHashMap<String, DateTime> _negativeUntil = LinkedHashMap<String, DateTime>();
  bool _disposed = false;

  @override
  Future<List<int>?> resolve(BookCoverRequest request) async {
    _ensureOpen();
    final url = request.coverUrl;
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    final key = CoverKey(
      pluginId: request.pluginId,
      pluginVersion: request.pluginVersion,
      remoteContentId: request.remoteContentId,
      coverUrl: url,
    );
    try {
      final persisted = await _library.covers.read(key);
      if (persisted != null && persisted.isNotEmpty) return persisted;
    } on Object {
      // A recoverable cache read failure may still fall through to the source.
    }
    final legacyLibraryItemId = request.legacyLibraryItemId;
    if (legacyLibraryItemId != null) {
      try {
        final legacy = await _library.bookshelf.readCover(LibraryItemId(legacyLibraryItemId));
        if (legacy != null && legacy.isNotEmpty) {
          try {
            await _library.covers.save(key: key, bytes: legacy);
          } on Object {
            // The legacy result remains immediately usable.
          }
          return legacy;
        }
      } on Object {
        // A legacy migration failure must not block a fresh network cover.
      }
    }
    _ensureOpen();
    final identity = key.canonicalValue;
    final now = _clock();
    final negativeUntil = _negativeUntil[identity];
    if (negativeUntil != null) {
      if (now.isBefore(negativeUntil)) return null;
      _negativeUntil.remove(identity);
    }
    final active = _remoteLoads[identity];
    if (active != null) return active;
    final task = _fetchAndPersist(key, url);
    _remoteLoads[identity] = task;
    try {
      return await task;
    } finally {
      if (identical(_remoteLoads[identity], task)) _remoteLoads.remove(identity);
    }
  }

  Future<List<int>?> _fetchAndPersist(CoverKey key, Uri url) async {
    try {
      final fetched = await (_externalFetcher?.call(url) ?? _httpClientOwner!.fetch(url));
      if (_disposed) throw StateError('Source cover persistence is disposed.');
      if (fetched == null || fetched.isEmpty) {
        _rememberFailure(key.canonicalValue);
        return null;
      }
      try {
        await _library.covers.save(key: key, bytes: fetched);
      } on Object {
        // Keep the freshly fetched bytes usable; retry persistence later.
      }
      _negativeUntil.remove(key.canonicalValue);
      return fetched;
    } on StateError {
      if (_disposed) rethrow;
      _rememberFailure(key.canonicalValue);
      return null;
    } on Object {
      _rememberFailure(key.canonicalValue);
      return null;
    }
  }

  void _rememberFailure(String identity) {
    _negativeUntil
      ..remove(identity)
      ..[identity] = _clock().add(_negativeCacheDuration);
    while (_negativeUntil.length > _maximumNegativeEntries) {
      _negativeUntil.remove(_negativeUntil.keys.first);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _negativeUntil.clear();
    await _httpClientOwner?.dispose();
    if (_remoteLoads.isNotEmpty) {
      await Future.wait<void>([for (final load in _remoteLoads.values) load.then<void>((_) {}, onError: (Object _, StackTrace _) {})]);
    }
    _remoteLoads.clear();
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('Source cover persistence is disposed.');
  }
}

typedef SourceCoverFetcher = Future<List<int>?> Function(Uri uri);
typedef SourceCoverHttpClientFactory = Future<HttpClient> Function();
typedef SourceCoverHttpClientConfigurationKey = Object? Function();

Future<HttpClient> _createSystemHttpClient() async => HttpClient();

/// Owns one lazy HTTP client for the application cover-loader lifetime.
final class SourceCoverHttpClientOwner {
  SourceCoverHttpClientOwner(this._factory, {SourceCoverHttpClientConfigurationKey? configurationKey, int maximumConcurrentLoads = 6})
    : _configurationKey = configurationKey ?? _directConfigurationKey,
      _permits = _AsyncPermitPool(maximumConcurrentLoads);

  final SourceCoverHttpClientFactory _factory;
  final SourceCoverHttpClientConfigurationKey _configurationKey;
  final _AsyncPermitPool _permits;
  final Set<Future<void>> _loads = <Future<void>>{};
  HttpClient? _client;
  Object? _clientConfiguration;
  Future<void>? _clientLoading;
  bool _disposed = false;

  Future<List<int>?> fetch(Uri uri) {
    if (_disposed) return Future<List<int>?>.error(StateError('Source cover HTTP client is disposed.'));
    final task = _withPermit(uri);
    late final Future<void> tracked;
    tracked = task.then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(() => _loads.remove(tracked));
    _loads.add(tracked);
    return task;
  }

  Future<List<int>?> _withPermit(Uri uri) async {
    await _permits.acquire();
    try {
      if (_disposed) throw StateError('Source cover HTTP client is disposed.');
      return await fetchSourceCover(uri, client: await _ensureClient());
    } finally {
      _permits.release();
    }
  }

  Future<HttpClient> _ensureClient() async {
    while (true) {
      if (_disposed) throw StateError('Source cover HTTP client is disposed.');
      final desiredConfiguration = _configurationKey();
      final current = _client;
      if (current != null && _clientConfiguration == desiredConfiguration) return current;
      final loading = _clientLoading;
      if (loading != null) {
        await loading;
        continue;
      }
      final operation = _initializeClient(desiredConfiguration);
      _clientLoading = operation;
      try {
        await operation;
      } finally {
        if (identical(_clientLoading, operation)) _clientLoading = null;
      }
    }
  }

  Future<void> _initializeClient(Object? configuration) async {
    final created = await _factory();
    if (_disposed) {
      created.close(force: true);
      throw StateError('Source cover HTTP client is disposed.');
    }
    created
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15)
      ..maxConnectionsPerHost = 4;
    final previous = _client;
    _client = created;
    _clientConfiguration = configuration;
    previous?.close();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _permits.close();
    _client?.close(force: true);
    final loading = _clientLoading;
    if (loading != null) {
      try {
        await loading;
      } on Object {
        // Initialization observes disposal and closes any late-created client.
      }
    }
    if (_loads.isNotEmpty) await Future.wait<void>(_loads.toList(growable: false));
    _client = null;
    _clientConfiguration = null;
  }
}

Future<List<int>?> fetchSourceCover(Uri uri, {required HttpClient client}) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
  request.followRedirects = true;
  request.maxRedirects = 3;
  final response = await request.close().timeout(const Duration(seconds: 15));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    await _discardResponse(response);
    return null;
  }
  final contentType = response.headers.contentType;
  if (contentType != null && contentType.primaryType.toLowerCase() != 'image') {
    await _discardResponse(response);
    return null;
  }
  if (response.contentLength > _maximumCoverBytes) {
    await _discardResponse(response);
    return null;
  }
  final builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in response.timeout(const Duration(seconds: 15))) {
    length += chunk.length;
    if (length > _maximumCoverBytes) return null;
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  return bytes.isEmpty ? null : bytes;
}

Future<void> _discardResponse(HttpClientResponse response) async {
  var length = 0;
  await for (final chunk in response.timeout(const Duration(seconds: 15))) {
    length += chunk.length;
    if (length > _maximumDiscardedResponseBytes) return;
  }
}

const int _maximumCoverBytes = 5 * 1024 * 1024;
const int _maximumDiscardedResponseBytes = 64 * 1024;
const String _directClientConfiguration = 'direct';

Object _directConfigurationKey() => _directClientConfiguration;

final class _AsyncPermitPool {
  _AsyncPermitPool(this._maximum) : assert(_maximum > 0), _available = _maximum;

  final int _maximum;
  int _available;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  bool _closed = false;

  Future<void> acquire() {
    if (_closed) return Future<void>.error(StateError('Source cover HTTP client is disposed.'));
    if (_available > 0) {
      _available -= 1;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void release() {
    if (_closed) return;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.isCompleted) continue;
      waiter.complete();
      return;
    }
    if (_available < _maximum) _available += 1;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(StateError('Source cover HTTP client is disposed.'));
    }
  }
}
