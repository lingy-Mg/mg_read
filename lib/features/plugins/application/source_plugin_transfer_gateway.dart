/// Narrow Runtime transfer port used by online source update checks.
///
/// Ownership:
/// - Adapts the Runtime Facade's typed artifact planning and import calls for
///   the plugins application feature.
///
/// Lifecycle and IO:
/// - The process-scoped Runtime Facade owns startup, transport, and install IO.
/// - Callers provide validated catalog metadata and lazily verified bytes.
///
/// Notes:
/// - This app-layer port does not expose Runtime transport details.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

final sourcePluginTransferGatewayProvider = Provider<SourcePluginTransferGateway>(
  (Ref ref) => MgReadSourcePluginTransferGateway(ref.watch(pluginRuntimeFacadeProvider)),
);

abstract interface class SourcePluginTransferGateway {
  Future<List<PluginTransferPlanItem>> plan(List<PluginTransferArtifact> artifacts);

  Future<List<PluginTransferImportResult>> importArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  });
}

final class MgReadSourcePluginTransferGateway implements SourcePluginTransferGateway {
  const MgReadSourcePluginTransferGateway(this._runtime);

  final PluginRuntime _runtime;

  @override
  Future<List<PluginTransferPlanItem>> plan(List<PluginTransferArtifact> artifacts) =>
      _runtime.invoke(PluginTransferPlanInvocation(artifacts: artifacts));

  @override
  Future<List<PluginTransferImportResult>> importArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) => _runtime.importPluginArtifacts(artifacts, forceUpgradePluginIds: forceUpgradePluginIds);
}
