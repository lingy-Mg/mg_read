/// Durable TV navigation projection: labels and opaque targets only, never content.
/// The app bridge reads it synchronously from initialized settings before Runtime
/// startup. Invalid/future snapshots are cache misses and cannot break settings.
library;

import 'package:flutter/foundation.dart';
import 'tv_discovery_session.dart';

@immutable
class TvDiscoveryNavigationSnapshot {
  TvDiscoveryNavigationSnapshot({required this.sourceId, required this.pluginVersion, required Iterable<TvDiscoveryTab> tabs})
    : tabs = List.unmodifiable(tabs);

  final String sourceId;
  final String pluginVersion;
  final List<TvDiscoveryTab> tabs;

  bool get canPersist =>
      tabs.isNotEmpty &&
      tabs.length <= 256 &&
      sourceId.length + pluginVersion.length + tabs.fold<int>(0, (sum, tab) => sum + tab.label.length + (tab.target?.length ?? 0)) <=
          64 * 1024;

  bool contains(String? target) => tabs.any((tab) => tab.target == target);

  bool sameNavigation(TvDiscoveryNavigationSnapshot other) => sourceId == other.sourceId && sameTabs(tabs, other.tabs);

  static bool sameTabs(List<TvDiscoveryTab> left, List<TvDiscoveryTab> right) =>
      left.length == right.length &&
      Iterable.generate(left.length).every((i) => left[i].label == right[i].label && left[i].target == right[i].target);

  Map<String, Object?> toJson() => {
    'version': 1,
    'sourceId': sourceId,
    'pluginVersion': pluginVersion,
    'tabs': [
      for (final tab in tabs) {'label': tab.label, 'target': tab.target},
    ],
  };

  static TvDiscoveryNavigationSnapshot? fromJson(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    final source = value['sourceId'];
    final version = value['pluginVersion'];
    final rawTabs = value['tabs'];
    if (source is! String || source.isEmpty || version is! String || rawTabs is! List || rawTabs.isEmpty || rawTabs.length > 256) {
      return null;
    }
    final tabs = <TvDiscoveryTab>[];
    final targets = <String?>{};
    for (final raw in rawTabs) {
      if (raw is! Map || raw['label'] is! String || (raw['label'] as String).trim().isEmpty || !raw.containsKey('target')) return null;
      final target = raw['target'];
      if (target != null && target is! String) return null;
      if (!targets.add(target as String?)) return null;
      tabs.add(TvDiscoveryTab(label: raw['label'] as String, target: target));
    }
    if (tabs.first.target != null) return null;
    final snapshot = TvDiscoveryNavigationSnapshot(sourceId: source, pluginVersion: version, tabs: tabs);
    return snapshot.canPersist ? snapshot : null;
  }
}
