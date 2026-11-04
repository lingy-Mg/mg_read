/// Phone/TV network policy. Ethernet is valid for companion services while the
/// existing Android file-sync Wi-Fi policy remains independent. Permission is
/// requested only after an explicit connection/receiver action.
library;

import 'dart:io';
import 'package:flutter/services.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';

class CompanionNetwork {
  const CompanionNetwork();
  static const _channel = MethodChannel('mgread/network_environment');
  Future<bool> available() async {
    try {
      if (Platform.isAndroid && await _channel.invokeMethod<bool>('isLanConnected') != true) return false;
      return (await eligibleLanSyncAddresses()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestLocalNetworkPermission') ?? false;
  }

  Future<List<String>> addresses() => eligibleLanSyncAddresses();
}
