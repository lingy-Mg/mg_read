import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

import '../core/settings/settings_testkit.dart';

/// Provides the initialized settings boundary required by [MgReadApp] tests.
Future<AppSettingsManager> createTestAppSettings({
  String themeMode = 'system',
}) async {
  final FakeSettingsStore store = FakeSettingsStore();
  if (themeMode != 'system') {
    store.documents[AppSettingKeys.appearanceDocument.kind] = SettingsDocument(
      id: AppSettingKeys.appearanceDocument.id,
      kind: AppSettingKeys.appearanceDocument.kind,
      values: <String, Object?>{AppSettingKeys.themeMode.id: themeMode},
      revision: 1,
    );
  }
  final AppSettingsManager settings = AppSettingsManager(
    store: store,
    registry: AppSettingKeys.registry,
  );
  await settings.initialize();
  return settings;
}

Widget testMgReadApp(
  AppSettingsManager settings, {
  DiagnosticsManager? diagnostics,
  SourceContentGateway sourceGateway = const _EmptySourceContentGateway(),
  PluginRuntimeGateway runtimeGateway = const TestReadyPluginRuntimeGateway(),
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWithValue(settings),
      sourceContentGatewayProvider.overrideWithValue(sourceGateway),
      pluginRuntimeGatewayProvider.overrideWithValue(runtimeGateway),
      if (diagnostics != null)
        diagnosticsManagerProvider.overrideWithValue(diagnostics),
    ],
    child: const MgReadApp(),
  );
}

/// Keeps host-widget tests independent from a platform Runtime process.
final class TestReadyPluginRuntimeGateway implements PluginRuntimeGateway {
  const TestReadyPluginRuntimeGateway();

  @override
  Future<PluginRuntimeConnection> inspect() async =>
      const PluginRuntimeConnection(
        isHealthy: true,
        nodeVersion: '24.16.0',
        runtimeVersion: 'test-runtime',
        plugins: <PluginRuntimePlugin>[],
      );

  @override
  Future<void> setEnabled({
    required String pluginId,
    required bool enabled,
  }) async {}
}

final class _EmptySourceContentGateway implements SourceContentGateway {
  const _EmptySourceContentGateway();

  @override
  Future<List<PluginSourceDescriptor>> listSources() async {
    return const <PluginSourceDescriptor>[];
  }

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) async => throw StateError('No source is installed in the app testkit.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async => throw StateError('No source is installed in the app testkit.');

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => throw StateError('No source is installed in the app testkit.');

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) async => throw StateError('No source is installed in the app testkit.');

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async => throw StateError('No source is installed in the app testkit.');
}
