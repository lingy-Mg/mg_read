/// App 制品发现、准备和平台安装的应用边界。
///
/// 网络层只接触不可变的 [PreparedAppPackage]；接收完成后由平台实现把文件交给
/// Android 系统安装器或 Windows 外部更新器。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/lan_sync/data/platform_app_update_service.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) => PlatformAppUpdateService());

abstract interface class AppUpdateService {
  Future<AppVersionInfo> currentVersion();

  /// Includes the current platform and any explicitly supported debug package.
  Future<List<AppPackageOffer>> availablePackages();

  Future<PreparedAppPackage> preparePackage(AppUpdatePlatform platform);

  /// Opens platform settings and fails before a download when user permission
  /// is still required. Desktop implementations are a no-op.
  Future<void> ensureInstallPermission();

  /// Hands an already verified package to the system installer/updater.
  Future<void> launchInstaller(File package, AppPackageDescriptor descriptor);
}

final class PreparedAppPackage {
  PreparedAppPackage({required this.descriptor, required this.file, this.onClose});

  final AppPackageDescriptor descriptor;
  final File file;
  final Future<void> Function()? onClose;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await onClose?.call();
  }
}
