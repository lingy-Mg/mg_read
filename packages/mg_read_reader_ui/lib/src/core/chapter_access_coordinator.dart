import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../api/contracts.dart';
import '../api/models.dart';

@immutable
class ReaderChapterAccessSnapshot {
  ReaderChapterAccessSnapshot({
    required Map<String, ReaderChapterState> states,
    required this.loading,
    required this.failure,
  }) : states = Map<String, ReaderChapterState>.unmodifiable(states);

  const ReaderChapterAccessSnapshot.initial()
    : states = const <String, ReaderChapterState>{},
      loading = false,
      failure = null;

  final Map<String, ReaderChapterState> states;
  final bool loading;
  final Object? failure;
}

/// Session-scoped state loader for host-owned chapter availability metadata.
class ReaderChapterAccessCoordinator extends ChangeNotifier {
  ReaderChapterAccessCoordinator({
    required String bookId,
    required ReaderChapterStateCapability capability,
  }) : this._(bookId, capability);

  ReaderChapterAccessCoordinator._(this._bookId, this._capability);

  String _bookId;
  ReaderChapterStateCapability _capability;
  ReaderChapterAccessSnapshot _snapshot =
      const ReaderChapterAccessSnapshot.initial();
  Map<String, ReaderChapterState> _baseStates =
      const <String, ReaderChapterState>{};
  final LinkedHashSet<String> _optimisticReadIds = LinkedHashSet<String>();
  final Map<String, Object> _markReadTokens = <String, Object>{};
  int _bindingGeneration = 0;
  int _refreshGeneration = 0;
  bool _disposed = false;

  static const int maximumBatchSize = 200;
  static const int maximumOptimisticReadEntries = 64;
  static const int maximumConcurrentMarkRead = 8;

  ReaderChapterAccessSnapshot get snapshot => _snapshot;

  bool isMarkingRead(String chapterId) =>
      _markReadTokens.containsKey(chapterId.trim());

  void rebind({
    required String bookId,
    required ReaderChapterStateCapability capability,
  }) {
    if (_bookId == bookId && identical(_capability, capability)) return;
    _bindingGeneration++;
    _refreshGeneration++;
    _bookId = bookId;
    _capability = capability;
    _markReadTokens.clear();
    _baseStates = const <String, ReaderChapterState>{};
    _optimisticReadIds.clear();
    _publish(const ReaderChapterAccessSnapshot.initial());
  }

  Future<void> refresh(Iterable<String> chapterIds) async {
    if (_disposed) return;
    final int bindingGeneration = _bindingGeneration;
    final int refreshGeneration = ++_refreshGeneration;
    final String bookId = _bookId;
    final ReaderChapterStateCapability capability = _capability;
    late final List<String> ids;
    try {
      ids = _normalizeIds(chapterIds);
    } catch (error) {
      if (!_isRefreshCurrent(
        bindingGeneration,
        refreshGeneration,
        bookId,
        capability,
      )) {
        return;
      }
      _publish(
        ReaderChapterAccessSnapshot(
          states: _effectiveStates(),
          loading: false,
          failure: error,
        ),
      );
      return;
    }
    if (ids.isEmpty) {
      _baseStates = const <String, ReaderChapterState>{};
      _optimisticReadIds.clear();
      _publish(const ReaderChapterAccessSnapshot.initial());
      return;
    }
    _publish(
      ReaderChapterAccessSnapshot(
        states: _effectiveStates(),
        loading: true,
        failure: null,
      ),
    );
    try {
      final Map<String, ReaderChapterState> response = await capability
          .loadChapterStates(bookId, ids);
      if (!_isRefreshCurrent(
        bindingGeneration,
        refreshGeneration,
        bookId,
        capability,
      )) {
        return;
      }
      final Set<String> requested = ids.toSet();
      final Map<String, ReaderChapterState> validated =
          <String, ReaderChapterState>{};
      for (final MapEntry<String, ReaderChapterState> entry
          in response.entries) {
        if (!requested.contains(entry.key) ||
            entry.key.trim().isEmpty ||
            entry.value.chapterId != entry.key ||
            (entry.value.wordCount != null && entry.value.wordCount! < 0)) {
          throw const ReaderChapterAccessException(
            'Chapter state response does not match the requested chapters.',
          );
        }
        validated[entry.key] = entry.value;
      }
      _baseStates = Map<String, ReaderChapterState>.unmodifiable(validated);
      _optimisticReadIds.retainAll(requested);
      for (final ReaderChapterState state in validated.values) {
        if (state.hasBeenRead) _optimisticReadIds.remove(state.chapterId);
      }
      _publish(
        ReaderChapterAccessSnapshot(
          states: _effectiveStates(),
          loading: false,
          failure: null,
        ),
      );
    } catch (error) {
      if (!_isRefreshCurrent(
        bindingGeneration,
        refreshGeneration,
        bookId,
        capability,
      )) {
        return;
      }
      _publish(
        ReaderChapterAccessSnapshot(
          states: _effectiveStates(),
          loading: false,
          failure: error,
        ),
      );
    }
  }

  Future<bool> markRead(String chapterId) async {
    final String id = chapterId.trim();
    if (_disposed ||
        id.isEmpty ||
        _markReadTokens.length >= maximumConcurrentMarkRead ||
        _markReadTokens.containsKey(id)) {
      return false;
    }
    final Object token = Object();
    _markReadTokens[id] = token;
    final int generation = _bindingGeneration;
    final String bookId = _bookId;
    final ReaderChapterStateCapability capability = _capability;
    notifyListeners();
    try {
      await capability.markRead(bookId, id);
      if (!_isCurrent(generation, bookId, capability)) return false;
      _optimisticReadIds.remove(id);
      _optimisticReadIds.add(id);
      while (_optimisticReadIds.length > maximumOptimisticReadEntries) {
        _optimisticReadIds.remove(_optimisticReadIds.first);
      }
      _publish(
        ReaderChapterAccessSnapshot(
          states: _effectiveStates(),
          loading: _snapshot.loading,
          failure: null,
        ),
      );
      return true;
    } catch (error) {
      if (_isCurrent(generation, bookId, capability)) {
        _publish(
          ReaderChapterAccessSnapshot(
            states: _effectiveStates(),
            loading: _snapshot.loading,
            failure: error,
          ),
        );
      }
      return false;
    } finally {
      final bool ownsToken = identical(_markReadTokens[id], token);
      if (ownsToken) _markReadTokens.remove(id);
      if (_isCurrent(generation, bookId, capability) && ownsToken) {
        notifyListeners();
      }
    }
  }

  List<String> _normalizeIds(Iterable<String> chapterIds) {
    final Set<String> seen = <String>{};
    final List<String> normalized = <String>[];
    for (final String value in chapterIds) {
      final String id = value.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      if (normalized.length >= maximumBatchSize) {
        throw const ReaderChapterAccessException(
          'Chapter state request exceeds the supported batch limit.',
        );
      }
      normalized.add(id);
    }
    return normalized;
  }

  Map<String, ReaderChapterState> _effectiveStates() {
    final Map<String, ReaderChapterState> effective =
        <String, ReaderChapterState>{..._baseStates};
    for (final String id in _optimisticReadIds) {
      final ReaderChapterState current =
          effective[id] ?? ReaderChapterState(chapterId: id);
      effective[id] = ReaderChapterState(
        chapterId: current.chapterId,
        availability: current.availability,
        wordCount: current.wordCount,
        hasBeenRead: true,
      );
    }
    return effective;
  }

  bool _isCurrent(
    int generation,
    String bookId,
    ReaderChapterStateCapability capability,
  ) =>
      !_disposed &&
      generation == _bindingGeneration &&
      bookId == _bookId &&
      identical(capability, _capability);

  bool _isRefreshCurrent(
    int bindingGeneration,
    int refreshGeneration,
    String bookId,
    ReaderChapterStateCapability capability,
  ) =>
      _isCurrent(bindingGeneration, bookId, capability) &&
      refreshGeneration == _refreshGeneration;

  void _publish(ReaderChapterAccessSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindingGeneration++;
    _refreshGeneration++;
    _markReadTokens.clear();
    _baseStates = const <String, ReaderChapterState>{};
    _optimisticReadIds.clear();
    super.dispose();
  }
}

@immutable
class ReaderChapterAccessException implements Exception {
  const ReaderChapterAccessException(this.message);

  final String message;

  @override
  String toString() => 'ReaderChapterAccessException($message)';
}
