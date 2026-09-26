/// App 传输真实 HTTP 测试夹具；仅替换包来源与系统安装边界，不启动真实安装器。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

final class TransferTestService implements AppUpdateService {
  TransferTestService({int build = 2, this.platform = AppUpdatePlatform.android})
    : version = AppVersionInfo(platform: platform, version: '1.0.$build', buildNumber: build);

  final AppUpdatePlatform platform;
  final AppVersionInfo version;
  final bytes = List<int>.generate(256 * 1024, (index) => index % 256);
  Completer<void>? permissionGate;
  Completer<void>? packageGate;
  Completer<void>? installerGate;
  Completer<void>? versionGate;
  bool permissionRequired = false;
  bool failInstaller = false;
  int permissionCalls = 0;
  int prepareCalls = 0;
  int installerCalls = 0;
  List<int>? installedBytes;
  Directory? root;

  @override
  Future<AppVersionInfo> currentVersion() async {
    await versionGate?.future;
    return version;
  }

  @override
  Future<List<AppPackageOffer>> availablePackages() async => [AppPackageOffer(version: version, available: true)];

  @override
  Future<void> ensureInstallPermission() async {
    permissionCalls++;
    await permissionGate?.future;
    if (permissionRequired) throw StateError('app_update_install_permission_required');
  }

  @override
  Future<PreparedAppPackage> preparePackage(AppUpdatePlatform platform) async {
    prepareCalls++;
    await packageGate?.future;
    root ??= await Directory.systemTemp.createTemp('mgread-app-transfer-flow-');
    final fileName = platform == AppUpdatePlatform.android ? 'mg_read.apk' : 'mg_read.zip';
    final file = File('${root!.path}/$fileName');
    await file.writeAsBytes(bytes);
    return PreparedAppPackage(
      descriptor: AppPackageDescriptor(version: version, bytes: bytes.length, checksum: lanSyncChecksum(bytes), fileName: fileName),
      file: file,
    );
  }

  @override
  Future<void> launchInstaller(File package, AppPackageDescriptor descriptor) async {
    installerCalls++;
    await installerGate?.future;
    if (failInstaller) throw StateError('app_update_installer_failed');
    installedBytes = await package.readAsBytes();
    await package.parent.delete(recursive: true);
  }

  Future<void> close() async {
    if (root case final directory? when await directory.exists()) await directory.delete(recursive: true);
  }
}

ProviderContainer transferContainer(TransferTestService service) {
  final container = ProviderContainer(
    overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
      lanSyncNetworkEnvironmentProvider.overrideWithValue(const TransferOfflineNetwork()),
    ],
  );
  final subscription = container.listen(appTransferControllerProvider, (_, _) {});
  addTearDown(() async {
    await container.read(appTransferControllerProvider.notifier).cancel();
    subscription.close();
    container.dispose();
    await service.close();
  });
  return container;
}

final class TransferOfflineNetwork implements LanSyncNetworkEnvironment {
  const TransferOfflineNetwork();

  @override
  Future<bool> isLocalNetworkAvailable() async => false;
}
