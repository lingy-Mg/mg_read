/// Explicit verification-only traversal of deferred whole-group catalogs.
/// UI and shelf prefetch must never use this exhaustive traversal. Gateway owns
/// I/O and cache; this temporary projection is discarded with the verification.
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

Future<PluginChaptersResult> loadVerificationCatalog(SourceContentGateway gateway, String pluginId, String id) async {
  final initial = await gateway.getChapters(pluginId: pluginId, id: id);
  if (!initial.groups.any((group) => group.deferred)) return initial;
  if (gateway is! SourceChapterGroupGateway) throw StateError('Deferred catalog loading unavailable.');
  final groups = <PluginMediaGroup>[];
  for (final group in initial.groups) {
    if (!group.deferred) {
      groups.add(group);
    } else {
      final result = await (gateway as SourceChapterGroupGateway).getChapterGroup(pluginId: pluginId, id: id, groupId: group.id);
      groups.add(result.groups.firstWhere((value) => value.id == group.id && !value.deferred));
    }
  }
  return PluginChaptersResult(
    pluginId: initial.pluginId,
    sourceName: initial.sourceName,
    groups: groups,
    items: groups.expand((group) => group.episodes).toList(),
  );
}
