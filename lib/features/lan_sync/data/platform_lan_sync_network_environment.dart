/// 局域网同步的真实平台网络判定。
///
/// Android 通过无运行时授权的系统网络能力查询确认 Wi-Fi；桌面以过滤后的私有 IPv4
/// 接口作为可用局域网依据。查询失败按不可用处理，避免在移动网络上盲目广播。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';

typedef AndroidWifiStatusResolver = Future<bool?> Function();
typedef LanSyncAddressResolver = Future<List<String>> Function();

final class PlatformLanSyncNetworkEnvironment implements LanSyncNetworkEnvironment {
  PlatformLanSyncNetworkEnvironment({
    bool? requiresAndroidWifi,
    AndroidWifiStatusResolver? androidWifiStatusResolver,
    LanSyncAddressResolver? addressResolver,
  }) : _requiresAndroidWifi = requiresAndroidWifi ?? Platform.isAndroid,
       _androidWifiStatusResolver = androidWifiStatusResolver ?? _readAndroidWifiStatus,
       _addressResolver = addressResolver ?? eligibleLanSyncAddresses;

  final bool _requiresAndroidWifi;
  final AndroidWifiStatusResolver _androidWifiStatusResolver;
  final LanSyncAddressResolver _addressResolver;

  @override
  Future<bool> isLocalNetworkAvailable() async {
    try {
      if (_requiresAndroidWifi) return await _androidWifiStatusResolver() ?? false;
      return (await _addressResolver()).isNotEmpty;
    } on Object {
      return false;
    }
  }
}

const MethodChannel _networkEnvironmentChannel = MethodChannel('mgread/network_environment');

Future<bool?> _readAndroidWifiStatus() => _networkEnvironmentChannel.invokeMethod<bool>('isWifiConnected');
