/// Bounded metadata-only group cache shared by source detail and player.
/// Owns five-minute TTL, four-entry LRU, single-flight and per-content refresh
/// generations. Failed or invalidated loads cannot become cached empty groups.
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

final class SourceChapterGroupCache {
  SourceChapterGroupCache({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _entries = <(String, String, String), ({DateTime expires, Future<PluginChaptersResult> value})>{};
  final _refresh = <(String, String)>{};
  final _known = <(String, String)>{};
  final _generations = <(String, String), Object>{};
  void remember(String plugin, String id) {
    _known.add((plugin, id));
    _generations.putIfAbsent((plugin, id), Object.new);
    if (_known.length > 32) {
      final oldest = _known.first;
      _known.remove(oldest);
      _generations.remove(oldest);
      _refresh.remove(oldest);
    }
  }

  bool takeRefresh(String plugin, String id) => _refresh.remove((plugin, id));
  void invalidate(String plugin, String id) {
    if (_known.contains((plugin, id))) _generations[(plugin, id)] = Object();
    _entries.removeWhere((key, _) => key.$1 == plugin && key.$2 == id);
    if (_known.contains((plugin, id))) _refresh.add((plugin, id));
  }

  Future<PluginChaptersResult> load(String plugin, String id, String group, Future<PluginChaptersResult> Function() fetch) {
    final key = (plugin, id, group);
    final now = _now();
    _entries.removeWhere((_, value) => value.expires.isBefore(now));
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit;
      return hit.value;
    }
    remember(plugin, id);
    final generation = _generations[(plugin, id)];
    late Future<PluginChaptersResult> task;
    task = fetch()
        .then((value) {
          if (!identical(generation, _generations[(plugin, id)])) throw StateError('Catalog was refreshed; retry the group.');
          return value;
        })
        .catchError((Object error, StackTrace stack) {
          if (identical(_entries[key]?.value, task)) _entries.remove(key);
          Error.throwWithStackTrace(error, stack);
        });
    _entries[key] = (expires: now.add(const Duration(minutes: 5)), value: task);
    while (_entries.length > 4) {
      _entries.remove(_entries.keys.first);
    }
    return task;
  }
}
