/// 配对设备 metadata 仓储公开边界。
///
/// 密钥由独立安全存储持有；本仓储只管理可展示和可撤销的同步策略。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

abstract interface class PairedDeviceRepository {
  Future<List<PairedDevice>> list();

  Future<PairedDevice?> read(String deviceId);

  Future<void> remove(String deviceId);

  Future<void> upsert(PairedDevice device);
}

final pairedDeviceRepositoryProvider = Provider<PairedDeviceRepository>((ref) => const _UnavailablePairedDeviceRepository());

final class _UnavailablePairedDeviceRepository implements PairedDeviceRepository {
  const _UnavailablePairedDeviceRepository();

  Never _unavailable() => throw StateError('paired_device_repository_unavailable');

  @override
  Future<List<PairedDevice>> list() async => _unavailable();

  @override
  Future<PairedDevice?> read(String deviceId) async => _unavailable();

  @override
  Future<void> remove(String deviceId) async => _unavailable();

  @override
  Future<void> upsert(PairedDevice device) async => _unavailable();
}
