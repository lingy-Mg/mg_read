import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../api/contracts.dart';
import '../../api/models.dart';
import '../../core/font_runtime.dart';
import 'reader_font_strings.dart';

/// Whether [descriptor] is safe for the reader's bounded runtime loader.
bool isCanonicalReaderFontDescriptor(ReaderFontDescriptor descriptor) {
  final String id = descriptor.id.trim();
  final String? version = descriptor.version;
  final String? digest = descriptor.sha256?.trim();
  final Set<int> weights = descriptor.weights.toSet();
  return id.isNotEmpty &&
      descriptor.id == id &&
      (version == null || (version.isNotEmpty && version == version.trim())) &&
      (digest == null ||
          digest.isEmpty ||
          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(digest)) &&
      descriptor.weights.length <= ReaderFontRuntime.maximumFontFaces &&
      weights.length == descriptor.weights.length &&
      weights.every(
        (int weight) => weight >= 100 && weight <= 900 && weight % 100 == 0,
      );
}

/// Loads every declared face and registers one stable runtime font identity.
///
/// Declared SHA-256 or version metadata is preferred. When neither exists,
/// the identity is derived from the actual cached bytes so a cache update
/// cannot silently reuse an older engine family.
Future<String> loadReaderRuntimeFont({
  required ReaderFontRepository repository,
  required ReaderFontDescriptor descriptor,
}) async {
  if (!isCanonicalReaderFontDescriptor(descriptor)) {
    throw const ReaderFontCatalogException(
      'Font descriptor is not canonical or exceeds runtime limits.',
    );
  }
  final List<int?> weights = descriptor.weights.isEmpty
      ? <int?>[null]
      : (<int>[
          ...descriptor.weights,
        ]..sort()).map<int?>((int value) => value).toList(growable: false);

  Future<Uint8List> bytesFor(int? weight) async {
    final Uint8List? bytes = await repository.loadCachedFontBytes(
      descriptor.id,
      version: descriptor.version,
      weight: weight,
    );
    if (bytes == null || bytes.isEmpty) {
      throw const ReaderFontCatalogException(
        ReaderFontStrings.cachedBytesMissing,
      );
    }
    return bytes;
  }

  final String? declaredIdentity = _declaredFontContentIdentity(descriptor);
  if (declaredIdentity == null) {
    final List<Uint8List> fonts = <Uint8List>[
      for (final int? weight in weights) await bytesFor(weight),
    ];
    return ReaderFontRuntime.instance.ensureLoaded(
      namespace: repository,
      fontId: descriptor.id,
      contentIdentity: _fontBytesContentIdentity(fonts),
      loadBytes: () async => fonts.first,
      additionalFonts: <ReaderFontByteLoader>[
        for (final Uint8List bytes in fonts.skip(1)) () async => bytes,
      ],
    );
  }
  return ReaderFontRuntime.instance.ensureLoaded(
    namespace: repository,
    fontId: descriptor.id,
    contentIdentity: declaredIdentity,
    loadBytes: () => bytesFor(weights.first),
    additionalFonts: <ReaderFontByteLoader>[
      for (final int? weight in weights.skip(1)) () => bytesFor(weight),
    ],
  );
}

String? _declaredFontContentIdentity(ReaderFontDescriptor descriptor) {
  final String faceIdentity = (<int>[...descriptor.weights]..sort()).join(',');
  final String? digest = descriptor.sha256?.trim().toLowerCase();
  if (digest != null && digest.isNotEmpty) {
    return 'sha256:$digest:faces:$faceIdentity';
  }
  final String? version = descriptor.version?.trim();
  if (version != null && version.isNotEmpty) {
    return 'version:$version:faces:$faceIdentity';
  }
  return null;
}

String _fontBytesContentIdentity(List<Uint8List> fonts) {
  const int offsetBasis = 0xcbf29ce484222325;
  const int prime = 0x100000001b3;
  const int mask = 0xffffffffffffffff;
  var hash = offsetBasis;
  var totalBytes = 0;
  for (final Uint8List bytes in fonts) {
    totalBytes += bytes.lengthInBytes;
    for (final int marker in <int>[
      bytes.lengthInBytes & 0xff,
      (bytes.lengthInBytes >> 8) & 0xff,
      (bytes.lengthInBytes >> 16) & 0xff,
      (bytes.lengthInBytes >> 24) & 0xff,
    ]) {
      hash = ((hash ^ marker) * prime) & mask;
    }
    for (final int byte in bytes) {
      hash = ((hash ^ byte) * prime) & mask;
    }
  }
  return 'bytes:${fonts.length}:$totalBytes:'
      '${hash.toRadixString(16).padLeft(16, '0')}';
}

@immutable
class ReaderFontCatalogSnapshot {
  ReaderFontCatalogSnapshot({
    required List<ReaderFontDescriptor> fonts,
    required Set<String> installedIds,
    required this.selectedFontId,
    required this.loading,
    required this.failure,
    required Map<String, Uint8List> previews,
    required Set<String> busyIds,
    required Set<String> metadataLoadedIds,
    required Set<String> metadataLoadingIds,
    required Map<String, Object> metadataFailures,
  }) : fonts = List<ReaderFontDescriptor>.unmodifiable(fonts),
       installedIds = Set<String>.unmodifiable(installedIds),
       previews = Map<String, Uint8List>.unmodifiable(previews),
       busyIds = Set<String>.unmodifiable(busyIds),
       metadataLoadedIds = Set<String>.unmodifiable(metadataLoadedIds),
       metadataLoadingIds = Set<String>.unmodifiable(metadataLoadingIds),
       metadataFailures = Map<String, Object>.unmodifiable(metadataFailures);

  const ReaderFontCatalogSnapshot.initial({this.selectedFontId})
    : fonts = const <ReaderFontDescriptor>[],
      installedIds = const <String>{},
      loading = false,
      failure = null,
      previews = const <String, Uint8List>{},
      busyIds = const <String>{},
      metadataLoadedIds = const <String>{},
      metadataLoadingIds = const <String>{},
      metadataFailures = const <String, Object>{};

  final List<ReaderFontDescriptor> fonts;
  final Set<String> installedIds;
  final String? selectedFontId;
  final bool loading;
  final Object? failure;
  final Map<String, Uint8List> previews;
  final Set<String> busyIds;
  final Set<String> metadataLoadedIds;
  final Set<String> metadataLoadingIds;
  final Map<String, Object> metadataFailures;
}

typedef ReaderFontSelectedCallback =
    FutureOr<void> Function(
      ReaderFontDescriptor descriptor,
      String runtimeFamily,
    );

class ReaderFontCatalogController extends ChangeNotifier {
  ReaderFontCatalogController({
    required ReaderFontRepository repository,
    ReaderFontSelectedCallback? onSelected,
    String? selectedFontId,
  }) : this._(
         repository,
         onSelected: onSelected,
         selectedFontId: selectedFontId,
       );

  ReaderFontCatalogController._(
    this._repository, {
    this.onSelected,
    String? selectedFontId,
  }) : _snapshot = ReaderFontCatalogSnapshot.initial(
         selectedFontId: selectedFontId,
       );

  ReaderFontRepository _repository;
  final ReaderFontSelectedCallback? onSelected;
  ReaderFontCatalogSnapshot _snapshot;
  final Map<String, Object> _mutationTokens = <String, Object>{};
  final Map<String, Object> _metadataTokens = <String, Object>{};
  final Set<String> _metadataLoadedIds = <String>{};
  final Map<String, Object> _metadataFailures = <String, Object>{};
  final LinkedHashMap<String, Uint8List> _previewLru =
      LinkedHashMap<String, Uint8List>();
  final Set<String> _previewUnavailableIds = <String>{};
  var _previewBytes = 0;
  int _bindingGeneration = 0;
  int _catalogGeneration = 0;
  bool _disposed = false;

  static const int maximumCatalogEntries = 200;
  static const int maximumPreviewBytes = 2 * 1024 * 1024;
  static const int maximumPreviewCacheBytes = 24 * 1024 * 1024;
  static const int maximumPreviewEntries = 24;
  ReaderFontCatalogSnapshot get snapshot => _snapshot;

  void rebind(ReaderFontRepository repository, {String? selectedFontId}) {
    if (identical(repository, _repository) &&
        selectedFontId == _snapshot.selectedFontId) {
      return;
    }
    _bindingGeneration++;
    _catalogGeneration++;
    _repository = repository;
    _clearTransientState();
    _publish(
      ReaderFontCatalogSnapshot.initial(
        selectedFontId: _normalizeOptionalId(selectedFontId),
      ),
    );
  }

  Future<void> loadCatalog() async {
    if (_disposed ||
        _snapshot.loading ||
        _mutationTokens.isNotEmpty ||
        _metadataTokens.isNotEmpty) {
      return;
    }
    final int bindingGeneration = _bindingGeneration;
    final int catalogGeneration = ++_catalogGeneration;
    final ReaderFontRepository repository = _repository;
    _publish(_copy(loading: true, clearFailure: true));
    try {
      final List<ReaderFontDescriptor> fonts = await repository.loadCatalog();
      if (!_isCatalogCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
      )) {
        return;
      }
      if (fonts.length > maximumCatalogEntries) {
        throw const ReaderFontCatalogException(
          'Font catalog exceeds the supported entry limit.',
        );
      }
      final Set<String> ids = <String>{};
      for (final ReaderFontDescriptor descriptor in fonts) {
        if (!isCanonicalReaderFontDescriptor(descriptor) ||
            descriptor.displayName.trim().isEmpty ||
            descriptor.familyName.trim().isEmpty ||
            !ids.add(descriptor.id.trim())) {
          throw const ReaderFontCatalogException(
            'Font catalog contains invalid or duplicate descriptors.',
          );
        }
      }
      _clearMetadataState();
      _publish(
        ReaderFontCatalogSnapshot(
          fonts: fonts,
          installedIds: const <String>{},
          selectedFontId: _snapshot.selectedFontId,
          loading: false,
          failure: null,
          previews: const <String, Uint8List>{},
          busyIds: _mutationTokens.keys.toSet(),
          metadataLoadedIds: const <String>{},
          metadataLoadingIds: const <String>{},
          metadataFailures: const <String, Object>{},
        ),
      );
    } catch (error) {
      if (_isCatalogCurrent(bindingGeneration, catalogGeneration, repository)) {
        _publish(_copy(loading: false, failure: error));
      }
    }
  }

  Future<void> ensureMetadata(ReaderFontDescriptor descriptor) async {
    if (_disposed || !_containsDescriptor(descriptor)) return;
    final String id = descriptor.id;
    _touchPreview(id);
    final bool needsInstalledState = !_metadataLoadedIds.contains(id);
    final bool needsPreview =
        !_previewLru.containsKey(id) && !_previewUnavailableIds.contains(id);
    if ((!needsInstalledState && !needsPreview) ||
        _metadataTokens.containsKey(id) ||
        _mutationTokens.containsKey(id)) {
      return;
    }

    final Object token = Object();
    _metadataTokens[id] = token;
    _metadataFailures.remove(id);
    final int bindingGeneration = _bindingGeneration;
    final int catalogGeneration = _catalogGeneration;
    final ReaderFontRepository repository = _repository;
    _publish(_copy(clearFailure: true));
    try {
      var installed = _snapshot.installedIds.contains(id);
      if (needsInstalledState) {
        installed = await _hasAllCachedFaces(repository, descriptor);
        if (!_isCatalogCurrent(
          bindingGeneration,
          catalogGeneration,
          repository,
        )) {
          return;
        }
      }

      Uint8List? preview;
      Object? previewFailure;
      if (needsPreview) {
        try {
          preview = await repository.loadCachedPreviewBytes(
            descriptor.id,
            version: descriptor.version,
          );
        } catch (error) {
          previewFailure = error;
        }
        if (!_isCatalogCurrent(
          bindingGeneration,
          catalogGeneration,
          repository,
        )) {
          return;
        }
      }

      final Set<String> installedIds = <String>{..._snapshot.installedIds};
      if (installed) {
        installedIds.add(id);
      } else {
        installedIds.remove(id);
      }
      if (needsInstalledState) _metadataLoadedIds.add(id);
      if (needsPreview) _acceptPreview(id, preview);
      _metadataFailures.remove(id);
      _publish(
        _copy(
          installedIds: installedIds,
          failure: previewFailure,
          clearFailure: previewFailure == null,
        ),
      );
    } catch (error) {
      if (_isCatalogCurrent(bindingGeneration, catalogGeneration, repository)) {
        _metadataFailures[id] = error;
        _publish(_copy(failure: error));
      }
    } finally {
      _finishMetadata(
        id,
        token,
        bindingGeneration,
        catalogGeneration,
        repository,
      );
    }
  }

  Future<bool> install(ReaderFontDescriptor descriptor) async {
    if (!_containsDescriptor(descriptor)) return false;
    final Object? token = _beginOperation(descriptor.id);
    if (token == null) return false;
    final int bindingGeneration = _bindingGeneration;
    final int catalogGeneration = _catalogGeneration;
    final ReaderFontRepository repository = _repository;
    try {
      await repository.install(descriptor);
      if (!_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        return false;
      }
      final String family = await loadReaderRuntimeFont(
        repository: repository,
        descriptor: descriptor,
      );
      if (!_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        return false;
      }
      Uint8List? preview;
      Object? previewFailure;
      try {
        preview = await repository.loadCachedPreviewBytes(
          descriptor.id,
          version: descriptor.version,
        );
      } catch (error) {
        previewFailure = error;
      }
      if (!_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        return false;
      }
      _metadataLoadedIds.add(descriptor.id);
      _metadataFailures.remove(descriptor.id);
      _previewUnavailableIds.remove(descriptor.id);
      _acceptPreview(descriptor.id, preview);
      _publish(
        _copy(
          installedIds: <String>{..._snapshot.installedIds, descriptor.id},
          failure: previewFailure,
          clearFailure: previewFailure == null,
        ),
      );
      return await _selectLoaded(
        descriptor,
        family,
        bindingGeneration: bindingGeneration,
        catalogGeneration: catalogGeneration,
        repository: repository,
      );
    } catch (error) {
      if (_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        _publish(_copy(failure: error));
      }
      return false;
    } finally {
      _finishOperation(descriptor.id, token);
    }
  }

  Future<bool> select(ReaderFontDescriptor descriptor) async {
    if (!_containsDescriptor(descriptor) ||
        !_snapshot.installedIds.contains(descriptor.id)) {
      return false;
    }
    final Object? token = _beginOperation(descriptor.id);
    if (token == null) return false;
    final int bindingGeneration = _bindingGeneration;
    final int catalogGeneration = _catalogGeneration;
    final ReaderFontRepository repository = _repository;
    try {
      final String family = await loadReaderRuntimeFont(
        repository: repository,
        descriptor: descriptor,
      );
      if (!_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        return false;
      }
      return await _selectLoaded(
        descriptor,
        family,
        bindingGeneration: bindingGeneration,
        catalogGeneration: catalogGeneration,
        repository: repository,
      );
    } catch (error) {
      if (_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        _publish(_copy(failure: error));
      }
      return false;
    } finally {
      _finishOperation(descriptor.id, token);
    }
  }

  Future<bool> remove(ReaderFontDescriptor descriptor) async {
    if (!_containsDescriptor(descriptor) ||
        _snapshot.selectedFontId == descriptor.id) {
      return false;
    }
    final Object? token = _beginOperation(descriptor.id);
    if (token == null) return false;
    final int bindingGeneration = _bindingGeneration;
    final int catalogGeneration = _catalogGeneration;
    final ReaderFontRepository repository = _repository;
    try {
      await repository.remove(descriptor.id);
      if (!_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        return false;
      }
      _metadataLoadedIds.add(descriptor.id);
      _metadataFailures.remove(descriptor.id);
      _removePreview(descriptor.id);
      _previewUnavailableIds.remove(descriptor.id);
      _publish(
        _copy(
          installedIds: <String>{..._snapshot.installedIds}
            ..remove(descriptor.id),
          clearFailure: true,
        ),
      );
      return true;
    } catch (error) {
      if (_isOperationCurrent(
        bindingGeneration,
        catalogGeneration,
        repository,
        descriptor,
      )) {
        _publish(_copy(failure: error));
      }
      return false;
    } finally {
      _finishOperation(descriptor.id, token);
    }
  }

  Future<bool> _selectLoaded(
    ReaderFontDescriptor descriptor,
    String family, {
    required int bindingGeneration,
    required int catalogGeneration,
    required ReaderFontRepository repository,
  }) async {
    if (!_isOperationCurrent(
      bindingGeneration,
      catalogGeneration,
      repository,
      descriptor,
    )) {
      return false;
    }
    await onSelected?.call(descriptor, family);
    if (!_isOperationCurrent(
      bindingGeneration,
      catalogGeneration,
      repository,
      descriptor,
    )) {
      return false;
    }
    _publish(_copy(selectedFontId: descriptor.id, clearFailure: true));
    return true;
  }

  Object? _beginOperation(String fontId) {
    if (_disposed ||
        _mutationTokens.isNotEmpty ||
        _metadataTokens.containsKey(fontId)) {
      return null;
    }
    final Object token = Object();
    _mutationTokens[fontId] = token;
    _publish(_copy(clearFailure: true));
    return token;
  }

  bool _containsDescriptor(ReaderFontDescriptor descriptor) =>
      _snapshot.fonts.any(
        (ReaderFontDescriptor candidate) =>
            identical(candidate, descriptor) ||
            (candidate.id == descriptor.id &&
                candidate.version == descriptor.version),
      );

  void _finishOperation(String fontId, Object token) {
    if (!identical(_mutationTokens[fontId], token)) return;
    _mutationTokens.remove(fontId);
    if (!_disposed) _publish(_copy());
  }

  bool _isCatalogCurrent(
    int bindingGeneration,
    int catalogGeneration,
    ReaderFontRepository repository,
  ) =>
      !_disposed &&
      bindingGeneration == _bindingGeneration &&
      catalogGeneration == _catalogGeneration &&
      identical(repository, _repository);

  bool _isOperationCurrent(
    int bindingGeneration,
    int catalogGeneration,
    ReaderFontRepository repository,
    ReaderFontDescriptor descriptor,
  ) =>
      _isCatalogCurrent(bindingGeneration, catalogGeneration, repository) &&
      _containsDescriptor(descriptor);

  ReaderFontCatalogSnapshot _copy({
    List<ReaderFontDescriptor>? fonts,
    Set<String>? installedIds,
    String? selectedFontId,
    bool clearSelectedFontId = false,
    bool? loading,
    Object? failure,
    bool clearFailure = false,
    Map<String, Uint8List>? previews,
    Set<String>? busyIds,
    Set<String>? metadataLoadedIds,
    Set<String>? metadataLoadingIds,
    Map<String, Object>? metadataFailures,
  }) => ReaderFontCatalogSnapshot(
    fonts: fonts ?? _snapshot.fonts,
    installedIds: installedIds ?? _snapshot.installedIds,
    selectedFontId: clearSelectedFontId
        ? null
        : selectedFontId ?? _snapshot.selectedFontId,
    loading: loading ?? _snapshot.loading,
    failure: clearFailure ? null : failure ?? _snapshot.failure,
    previews: previews ?? _previewLru,
    busyIds: busyIds ?? _mutationTokens.keys.toSet(),
    metadataLoadedIds: metadataLoadedIds ?? _metadataLoadedIds,
    metadataLoadingIds: metadataLoadingIds ?? _metadataTokens.keys.toSet(),
    metadataFailures: metadataFailures ?? _metadataFailures,
  );

  Future<bool> _hasAllCachedFaces(
    ReaderFontRepository repository,
    ReaderFontDescriptor descriptor,
  ) async {
    final List<int?> weights = descriptor.weights.isEmpty
        ? <int?>[null]
        : (<int>[
            ...descriptor.weights,
          ]..sort()).map<int?>((int value) => value).toList(growable: false);
    var combinedBytes = 0;
    for (final int? weight in weights) {
      final Uint8List? bytes = await repository.loadCachedFontBytes(
        descriptor.id,
        version: descriptor.version,
        weight: weight,
      );
      if (bytes == null || bytes.isEmpty) return false;
      combinedBytes += bytes.lengthInBytes;
      if (combinedBytes > ReaderFontRuntime.maximumFontBytes) return false;
    }
    return true;
  }

  String? _normalizeOptionalId(String? value) {
    final String? normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  void _acceptPreview(String id, Uint8List? preview) {
    _removePreview(id);
    if (preview == null || preview.isEmpty) {
      _previewUnavailableIds.add(id);
      return;
    }
    if (preview.lengthInBytes > maximumPreviewBytes) {
      _previewUnavailableIds.add(id);
      return;
    }
    final Uint8List owned = Uint8List.fromList(preview);
    _previewUnavailableIds.remove(id);
    _previewLru[id] = owned;
    _previewBytes += owned.lengthInBytes;
    while (_previewLru.length > maximumPreviewEntries ||
        _previewBytes > maximumPreviewCacheBytes) {
      final String oldest = _previewLru.keys.first;
      _removePreview(oldest);
    }
  }

  void _touchPreview(String id) {
    final Uint8List? preview = _previewLru.remove(id);
    if (preview != null) _previewLru[id] = preview;
  }

  void _removePreview(String id) {
    final Uint8List? removed = _previewLru.remove(id);
    if (removed != null) _previewBytes -= removed.lengthInBytes;
  }

  void _finishMetadata(
    String id,
    Object token,
    int bindingGeneration,
    int catalogGeneration,
    ReaderFontRepository repository,
  ) {
    if (!identical(_metadataTokens[id], token)) return;
    _metadataTokens.remove(id);
    if (_isCatalogCurrent(bindingGeneration, catalogGeneration, repository)) {
      _publish(_copy());
    }
  }

  void _clearMetadataState() {
    _metadataTokens.clear();
    _metadataLoadedIds.clear();
    _metadataFailures.clear();
    _previewLru.clear();
    _previewUnavailableIds.clear();
    _previewBytes = 0;
  }

  void _clearTransientState() {
    _mutationTokens.clear();
    _clearMetadataState();
  }

  void _publish(ReaderFontCatalogSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindingGeneration++;
    _catalogGeneration++;
    _clearTransientState();
    super.dispose();
  }
}

@immutable
class ReaderFontCatalogException implements Exception {
  const ReaderFontCatalogException(this.message);

  final String message;

  @override
  String toString() => 'ReaderFontCatalogException($message)';
}
