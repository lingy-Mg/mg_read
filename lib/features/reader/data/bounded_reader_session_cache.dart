/// Lightweight LRU storage for reader-session metadata and text bodies.
///
/// Entries are allocated lazily. The cache never scans persistent storage and
/// performs no work until a reader session inserts its first value.
library;

import 'dart:collection';

typedef ReaderSessionCacheWeight<K, V> = int Function(K key, V value);

/// A synchronous least-recently-used cache bounded by entries and weight.
final class BoundedReaderSessionCache<K, V> {
  BoundedReaderSessionCache({required this.maxEntries, this.maxWeight, ReaderSessionCacheWeight<K, V>? weightOf})
    : assert(maxEntries > 0),
      assert(maxWeight == null || maxWeight > 0),
      _weightOf = weightOf ?? ((K _, V _) => 1);

  final int maxEntries;
  final int? maxWeight;
  final ReaderSessionCacheWeight<K, V> _weightOf;
  final LinkedHashMap<K, _WeightedCacheEntry<V>> _entries = LinkedHashMap<K, _WeightedCacheEntry<V>>();
  int _weight = 0;

  int get length => _entries.length;
  int get weight => _weight;

  V? operator [](K key) {
    final _WeightedCacheEntry<V>? entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return entry.value;
  }

  void operator []=(K key, V value) {
    final _WeightedCacheEntry<V>? previous = _entries.remove(key);
    if (previous != null) _weight -= previous.weight;
    final int entryWeight = _weightOf(key, value);
    if (entryWeight < 0) {
      throw ArgumentError.value(entryWeight, 'weight', 'Cache weight must not be negative.');
    }
    final int? weightLimit = maxWeight;
    if (weightLimit != null && entryWeight > weightLimit) return;
    _entries[key] = _WeightedCacheEntry<V>(value, entryWeight);
    _weight += entryWeight;
    while (_entries.length > maxEntries || (weightLimit != null && _weight > weightLimit)) {
      final K oldest = _entries.keys.first;
      _weight -= _entries.remove(oldest)!.weight;
    }
  }

  void clear() {
    _entries.clear();
    _weight = 0;
  }
}

final class _WeightedCacheEntry<V> {
  const _WeightedCacheEntry(this.value, this.weight);

  final V value;
  final int weight;
}
