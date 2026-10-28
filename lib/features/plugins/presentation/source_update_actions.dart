/// Shared manual/automatic update presentation. Installation only follows an
/// explicit confirmation and uses Runtime's existing exclusive import lifecycle.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/app_update/application/update_check_result.dart';
import '../application/plugin_runtime_connection.dart';
import '../application/source_collection_import.dart';
import '../application/source_plugin_transfer_gateway.dart';
import '../application/source_update_coordinator.dart';
import 'source_collection_import_sheet.dart';

Future<void> checkSourceUpdates(BuildContext context, WidgetRef ref) async {
  final result = await ref.read(sourceUpdateCoordinatorProvider).check(force: true);
  if (!context.mounted) return;
  if (result.status != UpdateCheckStatus.available) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
    return;
  }
  await offerSourceUpdates(context, ref, result.value!);
}

Future<void> offerSourceUpdates(BuildContext context, WidgetRef ref, List<SourceCollectionCandidate> updates) async {
  if (ref.read(pluginRuntimeSourceImportProvider).isImporting) return;
  final importer = ref.read(pluginRuntimeSourceImportProvider.notifier);
  final gateway = ref.read(sourcePluginTransferGatewayProvider);
  try {
    final results = await importer.importSourceCollection(() async {
      if (!await showSourceUpdatesConfirmationDialog(context, updates) || !context.mounted) return null;
      final selection = sourceCollectionSelection(updates, {for (final item in updates) item.plugin.id});
      if (selection == null) return null;
      return gateway.importArtifacts(selection.artifacts, forceUpgradePluginIds: selection.forceUpgradePluginIds);
    }, initialMessage: '正在准备数据源更新');
    if (context.mounted && results != null) {
      final connection = await ref.read(pluginRuntimeConnectionProvider.future);
      if (!context.mounted) return;
      await showSourceCollectionImportResults(
        context,
        results,
        updates,
        onlineRepository: true,
        updating: true,
        pendingPluginIds: {
          for (final plugin in connection.plugins)
            if (plugin.pendingVersion != null) plugin.id,
        },
      );
    }
  } on Object {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源更新失败，请稍后重试。')));
  }
}
