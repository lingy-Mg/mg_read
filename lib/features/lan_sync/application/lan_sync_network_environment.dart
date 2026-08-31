/// 局域网同步可用网络的应用边界。
///
/// Android 实现只允许已连接的 Wi-Fi；桌面实现允许具备私有 IPv4 的本地网络。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class LanSyncNetworkEnvironment {
  Future<bool> isLocalNetworkAvailable();
}

final lanSyncNetworkEnvironmentProvider = Provider<LanSyncNetworkEnvironment>((ref) => const _UnavailableLanSyncNetworkEnvironment());

final class _UnavailableLanSyncNetworkEnvironment implements LanSyncNetworkEnvironment {
  const _UnavailableLanSyncNetworkEnvironment();

  @override
  Future<bool> isLocalNetworkAvailable() async => false;
}
