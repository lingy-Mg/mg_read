/// App TV-role changes expose LAN reception without creating paired sync trust.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/data/companion_network.dart';
import 'mg_read_app_test_support.dart';

void main() {
  testWidgets('TV startup receives directly and leaving TV mode closes reception', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, true);
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    final devices = _Devices();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          pluginRuntimeFacadeProvider.overrideWith(testPluginRuntimeFacade),
          pluginRuntimeGatewayProvider.overrideWithValue(const TestReadyPluginRuntimeGateway()),
          pluginRuntimeConnectionProvider.overrideWith(
            (ref) async => PluginRuntimeConnection(isHealthy: true, nodeVersion: 'test', runtimeVersion: 'test', plugins: const []),
          ),
          sourceContentGatewayProvider.overrideWithValue(_Sources()),
          deviceIdentityStoreProvider.overrideWithValue(_Identity()),
          pairedDeviceRepositoryProvider.overrideWithValue(devices),
          companionNetworkProvider.overrideWithValue(_Network()),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(MgReadApp)));
    final service = container.read(companionControllerProvider);
    expect(service.initialized, isTrue);
    expect(service.receiverEnabled, isTrue);
    expect(service.requiresHost, isTrue);
    expect(await devices.list(), isEmpty, reason: 'LAN control must not create sync trust');
    await settings.set(AppSettingKeys.tvMode, false);
    await tester.pumpAndSettle();
    expect(service.receiverEnabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _Identity implements DeviceIdentityStore {
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => const LocalDeviceIdentity(deviceId: 'tv-role-test', label: 'TV');
  @override
  Future<List<int>?> readPeerSecret(String id) async => null;
  @override
  Future<void> deletePeerSecret(String id) async {}
  @override
  Future<void> writePeerSecret(String id, List<int> key) async => throw StateError('LAN must not persist a shared secret');
}

final class _Devices implements PairedDeviceRepository {
  @override
  Future<List<PairedDevice>> list() async => [];
  @override
  Future<PairedDevice?> read(String id) async => null;
  @override
  Future<void> remove(String id) async {}
  @override
  Future<void> upsert(PairedDevice device) async => throw StateError('LAN must not pair');
}

final class _Network extends CompanionNetwork {
  @override
  Future<bool> available() async => false;
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<List<String>> addresses() async => [];
}

final class _Sources implements SourceContentGateway {
  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
