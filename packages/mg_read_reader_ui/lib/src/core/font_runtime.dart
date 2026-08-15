import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef ReaderFontByteLoader = Future<Uint8List> Function();

/// Process-wide bridge between host-supplied bytes and Flutter's font engine.
///
/// The runtime intentionally performs no download or persistence. Flutter
/// cannot unload a font from the engine, so a successfully registered family
/// remains resident even if the host later removes its installed asset.
class ReaderFontRuntime {
  ReaderFontRuntime._();

  static final ReaderFontRuntime instance = ReaderFontRuntime._();

  static const int maximumFontBytes = 64 * 1024 * 1024;
  static const int maximumFontFaces = 9;
  static const int maximumLoadedFamilies = 32;
  static const int maximumLoadedFontBytes = 256 * 1024 * 1024;

  final Map<_ReaderFontKey, String> _loadedFamilies =
      <_ReaderFontKey, String>{};
  final Map<_ReaderFontKey, Future<String>> _pendingLoads =
      <_ReaderFontKey, Future<String>>{};
  final Expando<int> _namespaceIds = Expando<int>('readerFontNamespace');
  int _nextNamespaceId = 0;
  int _nextFamilyAttempt = 0;
  int _consumedFamilySlots = 0;
  int _consumedFontBytes = 0;

  String? loadedFamily({
    required Object namespace,
    required String fontId,
    required String contentIdentity,
  }) {
    final _ReaderFontKey? key = _normalizedKey(
      namespace,
      fontId,
      contentIdentity,
    );
    return key == null ? null : _loadedFamilies[key];
  }

  bool isLoaded({
    required Object namespace,
    required String fontId,
    required String contentIdentity,
  }) =>
      loadedFamily(
        namespace: namespace,
        fontId: fontId,
        contentIdentity: contentIdentity,
      ) !=
      null;

  /// Registers one bounded font family and returns its private engine family.
  ///
  /// Concurrent callers for the same namespace, ID, and content identity share
  /// one operation. Failed operations are removed from the pending table so a
  /// later call creates a fresh [FontLoader] and a never-reused engine family.
  Future<String> ensureLoaded({
    required Object namespace,
    required String fontId,
    required String contentIdentity,
    required ReaderFontByteLoader loadBytes,
    List<ReaderFontByteLoader> additionalFonts = const <ReaderFontByteLoader>[],
  }) {
    final _ReaderFontKey key = _requireKey(namespace, fontId, contentIdentity);
    final String? loaded = _loadedFamilies[key];
    if (loaded != null) return Future<String>.value(loaded);
    return _pendingLoads.putIfAbsent(key, () {
      final Future<String> operation = _load(key, <ReaderFontByteLoader>[
        loadBytes,
        ...additionalFonts,
      ]);
      unawaited(
        operation.then<void>(
          (_) => _clearPending(key, operation),
          onError: (Object _, StackTrace _) => _clearPending(key, operation),
        ),
      );
      return operation;
    });
  }

  void _clearPending(_ReaderFontKey key, Future<String> operation) {
    if (identical(_pendingLoads[key], operation)) {
      _pendingLoads.remove(key);
    }
  }

  Future<String> _load(
    _ReaderFontKey key,
    List<ReaderFontByteLoader> byteLoaders,
  ) async {
    if (byteLoaders.isEmpty) {
      throw const ReaderFontRuntimeException('At least one font is required.');
    }
    if (byteLoaders.length > maximumFontFaces) {
      throw const ReaderFontRuntimeException(
        'A dynamic font family contains too many faces.',
      );
    }
    final List<Uint8List> fonts = <Uint8List>[];
    var combinedBytes = 0;
    for (final ReaderFontByteLoader loadBytes in byteLoaders) {
      final Uint8List bytes = await loadBytes();
      combinedBytes += bytes.lengthInBytes;
      if (bytes.isEmpty || combinedBytes > maximumFontBytes) {
        throw ReaderFontRuntimeException(
          bytes.isEmpty
              ? 'Font bytes must not be empty.'
              : 'Font family exceeds the $maximumFontBytes byte runtime limit.',
        );
      }
      fonts.add(bytes);
    }
    if (_consumedFamilySlots >= maximumLoadedFamilies ||
        _consumedFontBytes + combinedBytes > maximumLoadedFontBytes) {
      throw const ReaderFontRuntimeException(
        'The process-wide dynamic font budget has been exhausted.',
      );
    }
    final String family = _familyFor(key);
    final FontLoader loader = FontLoader(family);
    for (final Uint8List bytes in fonts) {
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    }

    // FontLoader registers faces sequentially. Once load starts, a later face
    // can fail after an earlier face has become process-resident. Charge the
    // whole attempt before entering the engine and never reuse its family.
    _consumedFamilySlots++;
    _consumedFontBytes += combinedBytes;
    await loader.load();
    _loadedFamilies[key] = family;
    return family;
  }

  String _familyFor(_ReaderFontKey key) {
    final String base = 'NovelReaderDynamic_${_fnv1a64(key.serialized)}';
    return '${base}_${_nextFamilyAttempt++}';
  }

  _ReaderFontKey _requireKey(
    Object namespace,
    String fontId,
    String contentIdentity,
  ) {
    final _ReaderFontKey? key = _normalizedKey(
      namespace,
      fontId,
      contentIdentity,
    );
    if (key == null) {
      throw const ReaderFontRuntimeException(
        'Font ID and content identity must contain visible text.',
      );
    }
    return key;
  }

  _ReaderFontKey? _normalizedKey(
    Object namespace,
    String fontId,
    String contentIdentity,
  ) {
    final String normalizedId = fontId.trim();
    final String normalizedIdentity = contentIdentity.trim();
    if (normalizedId.isEmpty || normalizedIdentity.isEmpty) return null;
    final int namespaceId = _namespaceIds[namespace] ??= _nextNamespaceId++;
    return _ReaderFontKey(namespaceId, normalizedId, normalizedIdentity);
  }

  String _fnv1a64(String value) {
    const int offsetBasis = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    const int mask = 0xffffffffffffffff;
    var hash = offsetBasis;
    for (final int byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

@immutable
class ReaderFontRuntimeException implements Exception {
  const ReaderFontRuntimeException(this.message);

  final String message;

  @override
  String toString() => 'ReaderFontRuntimeException($message)';
}

@immutable
class _ReaderFontKey {
  const _ReaderFontKey(this.namespaceId, this.fontId, this.contentIdentity);

  final int namespaceId;
  final String fontId;
  final String contentIdentity;

  String get serialized => '$namespaceId\u0000$fontId\u0000$contentIdentity';

  @override
  bool operator ==(Object other) =>
      other is _ReaderFontKey &&
      namespaceId == other.namespaceId &&
      fontId == other.fontId &&
      contentIdentity == other.contentIdentity;

  @override
  int get hashCode => Object.hash(namespaceId, fontId, contentIdentity);
}
