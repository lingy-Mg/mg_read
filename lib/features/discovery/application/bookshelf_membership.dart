import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A small source/title projection used to answer bookshelf questions without
/// querying persistence for every search or discovery row.
final class BookshelfMembershipEntry {
  const BookshelfMembershipEntry({required this.itemId, required this.pluginId, required this.title});

  final String itemId;
  final String pluginId;
  final String title;
}

abstract interface class BookshelfMembershipLoader {
  Future<Iterable<BookshelfMembershipEntry>> load();
}

final class EmptyBookshelfMembershipLoader
    implements BookshelfMembershipLoader {
  const EmptyBookshelfMembershipLoader();

  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async =>
      const <BookshelfMembershipEntry>[];
}

final bookshelfMembershipLoaderProvider = Provider<BookshelfMembershipLoader>(
  (Ref ref) => const EmptyBookshelfMembershipLoader(),
);

final class BookshelfMembershipState {
  const BookshelfMembershipState({required this.entriesByKey, required this.isLoaded});

  const BookshelfMembershipState.initial()
    : entriesByKey = const <String, BookshelfMembershipEntry>{},
      isLoaded = false;

  final Map<String, BookshelfMembershipEntry> entriesByKey;
  final bool isLoaded;

  bool contains({required String pluginId, required String title}) =>
      entry(pluginId: pluginId, title: title) != null;

  BookshelfMembershipEntry? entry({required String pluginId, required String title}) =>
      entriesByKey[bookshelfMembershipKey(pluginId: pluginId, title: title)];
}

/// Process-scoped O(1) bookshelf membership index shared by search, discovery
/// and source details. Loading is one bounded-paged pass, never one query per
/// result row.
final bookshelfMembershipProvider =
    NotifierProvider<BookshelfMembershipController, BookshelfMembershipState>(
      BookshelfMembershipController.new,
    );

class BookshelfMembershipController extends Notifier<BookshelfMembershipState> {
  late BookshelfMembershipLoader _loader;
  int _generation = 0;
  bool _disposed = false;
  Future<void>? _loadFuture;
  final Map<String, BookshelfMembershipEntry> _optimisticAdded = <String, BookshelfMembershipEntry>{};
  final Set<String> _optimisticRemoved = <String>{};

  @override
  BookshelfMembershipState build() {
    _loader = ref.watch(bookshelfMembershipLoaderProvider);
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(() => unawaited(_startLoad()));
    return const BookshelfMembershipState.initial();
  }

  bool contains({required String pluginId, required String title}) =>
      state.contains(pluginId: pluginId, title: title);

  Future<bool> containsWhenReady({
    required String pluginId,
    required String title,
  }) async {
    if (!state.isLoaded) await reload();
    return contains(pluginId: pluginId, title: title);
  }

  Future<BookshelfMembershipEntry?> entryWhenReady({required String pluginId, required String title}) async {
    if (!state.isLoaded) await reload();
    return state.entry(pluginId: pluginId, title: title);
  }

  /// Publishes a durable save immediately so a detail reopened after returning
  /// from it sees the same source/title membership without another SQL read.
  void markAdded({required String itemId, required String pluginId, required String title}) {
    if (_disposed) return;
    final entry = BookshelfMembershipEntry(itemId: itemId, pluginId: pluginId, title: title);
    final key = bookshelfMembershipKey(pluginId: pluginId, title: title);
    _optimisticAdded[key] = entry;
    _optimisticRemoved.remove(key);
    state = BookshelfMembershipState(
      entriesByKey: <String, BookshelfMembershipEntry>{...state.entriesByKey, key: entry},
      isLoaded: state.isLoaded,
    );
  }

  /// Hides one known shelf item immediately while its durable deletion runs.
  void markRemoved(BookshelfMembershipEntry entry) {
    if (_disposed) return;
    final key = bookshelfMembershipKey(pluginId: entry.pluginId, title: entry.title);
    _optimisticAdded.remove(key);
    _optimisticRemoved.add(key);
    state = BookshelfMembershipState(
      entriesByKey: <String, BookshelfMembershipEntry>{...state.entriesByKey}..remove(key),
      isLoaded: state.isLoaded,
    );
  }

  Future<void> reload() {
    return _startLoad();
  }

  Future<void> _startLoad() {
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;
    final generation = ++_generation;
    final future = _load(generation);
    _loadFuture = future;
    future.whenComplete(() {
      if (identical(_loadFuture, future)) _loadFuture = null;
    });
    return future;
  }

  Future<void> _load(int generation) async {
    try {
      final entries = await _loader.load();
      if (_disposed || generation != _generation) return;
      final entriesByKey = <String, BookshelfMembershipEntry>{
        for (final entry in entries)
          if (!_optimisticRemoved.contains(bookshelfMembershipKey(pluginId: entry.pluginId, title: entry.title)))
            bookshelfMembershipKey(pluginId: entry.pluginId, title: entry.title): entry,
        ..._optimisticAdded,
      };
      state = BookshelfMembershipState(
        entriesByKey: Map<String, BookshelfMembershipEntry>.unmodifiable(entriesByKey),
        isLoaded: true,
      );
    } on Object {
      // Membership is optional display state. Keep the last known projection
      // and allow the app to remain usable if the local read is unavailable.
    }
  }
}

String bookshelfMembershipKey({
  required String pluginId,
  required String title,
}) {
  return '${pluginId.trim()}\u001f${_normalizeBookTitle(title)}';
}

String _normalizeBookTitle(String title) =>
    title.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
