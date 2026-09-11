import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../api/comic_contracts.dart';
import '../../api/comic_models.dart';
import 'comic_image_dimensions.dart';

/// Session-local, encoded-byte cache for progressively loaded comic images.
///
/// Persistent storage remains the host's responsibility. Both entry and byte
/// limits are enforced because a count-only cache is unsafe for scan-quality
/// images with highly variable encoded sizes. The default 1000-entry ceiling
/// is only a safety cap: the 48 MiB byte budget remains primary, and storage is
/// allocated lazily as images finish downloading.
class ComicImageByteCache {
  ComicImageByteCache({
    required this.bookId,
    required this.dataSource,
    this.maxEntries = 1000,
    this.maxBytes = 48 * 1024 * 1024,
    this.maxSingleImageBytes = 8 * 1024 * 1024,
    this.maxConcurrentLoads = 4,
    this.maxQueuedLoads = 32,
    this.onDimensionsChanged,
  });

  final String bookId;
  final ComicReaderDataSource dataSource;
  final int maxEntries;
  final int maxBytes;
  final int maxSingleImageBytes;
  final int maxConcurrentLoads;
  final int maxQueuedLoads;
  final void Function()? onDimensionsChanged;
  final Map<String, double> _aspectRatios = <String, double>{};
  int dimensionsRevision = 0;

  double? aspectRatio(String chapterId, ComicImageInfo image) =>
      _aspectRatios[_key(chapterId, image)];

  /// Geometry survives byte eviction and is bounded by the chapter window.
  void retainGeometry(Set<String> chapterIds) {
    _aspectRatios.removeWhere(
      (key, _) => !chapterIds.contains(key.split('\u0000').first),
    );
  }

  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();
  final Map<String, _ImageRequest> _requests = <String, _ImageRequest>{};
  final ListQueue<_ImageRequest> _visibleQueue = ListQueue<_ImageRequest>();
  final ListQueue<_ImageRequest> _prefetchQueue = ListQueue<_ImageRequest>();
  final Map<String, int> _keyEpochs = <String, int>{};
  int _bytes = 0;
  int _generation = 0;
  int _activeLoads = 0;
  bool _disposed = false;

  int get entryCount => _entries.length;
  int get byteCount => _bytes;

  /// Whether encoded bytes for [image] are already retained in this session.
  bool contains(String chapterId, ComicImageInfo image) =>
      _entries.containsKey(_key(chapterId, image));

  Future<Uint8List> load(
    String chapterId,
    ComicImageInfo image, {
    bool forceRefresh = false,
    bool visiblePriority = true,
  }) {
    if (_disposed) {
      return Future<Uint8List>.error(
        StateError('The comic image cache has been disposed.'),
      );
    }
    final String key = _key(chapterId, image);
    if (forceRefresh) _invalidateRequest(key);
    final Uint8List? cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return Future<Uint8List>.value(cached);
    }
    final _ImageRequest? existing = _requests[key];
    if (existing != null) {
      if (visiblePriority && !existing.visiblePriority) {
        existing.visiblePriority = true;
        if (!existing.started) {
          _prefetchQueue.remove(existing);
          _visibleQueue.add(existing);
        }
      }
      return existing.completer.future;
    }

    if (_visibleQueue.length + _prefetchQueue.length >= maxQueuedLoads) {
      if (!visiblePriority) {
        return Future<Uint8List>.error(
          StateError('Comic image prefetch queue is full.'),
        );
      }
      final _ImageRequest? displaced = _prefetchQueue.isNotEmpty
          ? _prefetchQueue.removeFirst()
          : _visibleQueue.isNotEmpty
          ? _visibleQueue.removeFirst()
          : null;
      if (displaced != null) {
        if (identical(_requests[displaced.key], displaced)) {
          _requests.remove(displaced.key);
        }
        if (!displaced.completer.isCompleted) {
          displaced.completer.completeError(
            StateError('Comic image request was displaced by visible work.'),
          );
        }
      }
    }

    final _ImageRequest request = _ImageRequest(
      key: key,
      chapterId: chapterId,
      imageId: image.id,
      expectedByteLength: image.byteLength,
      generation: _generation,
      keyEpoch: _keyEpochs[key] ?? 0,
      visiblePriority: visiblePriority,
    );
    _requests[key] = request;
    (visiblePriority ? _visibleQueue : _prefetchQueue).add(request);
    _pump();
    return request.completer.future;
  }

  void prefetch(String chapterId, ComicImageInfo image) {
    load(chapterId, image, visiblePriority: false).ignore();
  }

  /// Drops warm encoded bytes and invalidates low-priority work.
  ///
  /// Visible requests remain active. Futures already executing cannot be
  /// cancelled, so removing their request identity prevents late prefetch
  /// results from repopulating the cache after memory pressure.
  void handleMemoryPressure() {
    if (_disposed) return;
    _entries.clear();
    _bytes = 0;
    cancelPrefetch();
  }

  void cancelPrefetch() {
    for (final _ImageRequest request in _requests.values.toList()) {
      if (request.visiblePriority) continue;
      if (!request.started) _prefetchQueue.remove(request);
      if (identical(_requests[request.key], request)) {
        _requests.remove(request.key);
      }
      if (!request.completer.isCompleted) {
        request.completer.completeError(
          StateError('Comic image prefetch was cancelled by memory pressure.'),
        );
      }
    }
    _pump();
  }

  void remove(String chapterId, ComicImageInfo image) {
    final String key = _key(chapterId, image);
    final Uint8List? value = _entries.remove(key);
    if (value != null) _bytes -= value.lengthInBytes;
  }

  void removeChapter(String chapterId) {
    final String prefix = '$chapterId\u0000';
    for (final String key
        in _entries.keys
            .where((String key) => key.startsWith(prefix))
            .toList()) {
      final Uint8List? value = _entries.remove(key);
      if (value != null) _bytes -= value.lengthInBytes;
    }
    for (final String key
        in _requests.keys
            .where((String key) => key.startsWith(prefix))
            .toList()) {
      _invalidateRequest(key);
    }
  }

  void _invalidateRequest(String key) {
    final Uint8List? value = _entries.remove(key);
    if (value != null) _bytes -= value.lengthInBytes;
    _keyEpochs[key] = (_keyEpochs[key] ?? 0) + 1;
    final _ImageRequest? previous = _requests.remove(key);
    if (previous != null) {
      if (!previous.started) {
        _visibleQueue.remove(previous);
        _prefetchQueue.remove(previous);
      }
      if (!previous.completer.isCompleted) {
        previous.completer.completeError(
          StateError('Comic image request was superseded.'),
        );
      }
    }
  }

  void _pump() {
    if (_disposed) return;
    while (_activeLoads < maxConcurrentLoads &&
        (_visibleQueue.isNotEmpty || _prefetchQueue.isNotEmpty)) {
      final _ImageRequest request = _visibleQueue.isNotEmpty
          ? _visibleQueue.removeFirst()
          : _prefetchQueue.removeFirst();
      if (!identical(_requests[request.key], request)) continue;
      request.started = true;
      _activeLoads++;
      _run(request);
    }
  }

  Future<void> _run(_ImageRequest request) async {
    try {
      final Uint8List bytes = await dataSource.loadImageBytes(
        bookId,
        request.chapterId,
        request.imageId,
      );
      if (bytes.isEmpty) {
        throw StateError('Comic image bytes must not be empty.');
      }
      if (bytes.lengthInBytes > maxSingleImageBytes) {
        throw StateError('Comic image exceeds the safe encoded-byte limit.');
      }
      if (request.expectedByteLength != null &&
          request.expectedByteLength != bytes.lengthInBytes) {
        throw StateError('Comic image byte length does not match metadata.');
      }
      // The host owns its mutable buffer. Retain a reader-owned copy so later
      // host reuse cannot corrupt cached or in-flight decoding bytes.
      final Uint8List ownedBytes = Uint8List.fromList(bytes);
      final bool current =
          !_disposed &&
          request.generation == _generation &&
          request.keyEpoch == (_keyEpochs[request.key] ?? 0) &&
          identical(_requests[request.key], request);
      if (current) {
        final double? ratio = comicEncodedAspectRatio(ownedBytes);
        if (ratio != null && _aspectRatios[request.key] != ratio) {
          _aspectRatios[request.key] = ratio;
          dimensionsRevision++;
          onDimensionsChanged?.call();
        }
        _insert(request.key, ownedBytes);
      }
      if (!request.completer.isCompleted) {
        if (!current) {
          request.completer.completeError(
            StateError('The comic image request is no longer active.'),
          );
        } else {
          request.completer.complete(ownedBytes);
        }
      }
    } catch (error, stackTrace) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, stackTrace);
      }
    } finally {
      if (identical(_requests[request.key], request)) {
        _requests.remove(request.key);
      }
      _activeLoads--;
      _pump();
    }
  }

  void _insert(String key, Uint8List bytes) {
    final Uint8List? old = _entries.remove(key);
    if (old != null) _bytes -= old.lengthInBytes;
    // A single oversized image may still be displayed by the caller, but is
    // intentionally not retained in this bounded session cache.
    if (bytes.lengthInBytes > maxBytes) return;
    _entries[key] = bytes;
    _bytes += bytes.lengthInBytes;
    while (_entries.length > maxEntries || _bytes > maxBytes) {
      final String oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.lengthInBytes;
    }
  }

  String _key(String chapterId, ComicImageInfo image) =>
      '$chapterId\u0000${image.id}\u0000${image.contentVersion ?? ''}';

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _aspectRatios.clear();
    _entries.clear();
    _bytes = 0;
    // Futures cannot be cancelled. Complete both queued and active callers now;
    // their generations also prevent late bytes from entering the cache.
    for (final _ImageRequest request in _requests.values.toList()) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(
          StateError('The comic image cache has been disposed.'),
        );
      }
    }
    _visibleQueue.clear();
    _prefetchQueue.clear();
    _requests.clear();
    _keyEpochs.clear();
  }
}

class _ImageRequest {
  _ImageRequest({
    required this.key,
    required this.chapterId,
    required this.imageId,
    required this.expectedByteLength,
    required this.generation,
    required this.keyEpoch,
    required this.visiblePriority,
  });

  final String key;
  final String chapterId;
  final String imageId;
  final int? expectedByteLength;
  final int generation;
  final int keyEpoch;
  final Completer<Uint8List> completer = Completer<Uint8List>();
  bool visiblePriority;
  bool started = false;
}
