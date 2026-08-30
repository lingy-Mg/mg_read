/// Typed app-owned proxy preferences and the Riverpod access point.
///
/// Responsibilities:
/// - Decode the persisted endpoint and independent traffic switches safely.
/// - Keep credentials out of the ordinary settings store and public models.
///
/// Notes:
/// - This model expresses intended routing only; network owners apply it at
///   their own typed boundaries.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/settings/settings.dart';

enum NetworkProxyProtocol { http, https, socks5 }

enum NetworkProxyTraffic { source, novel, manga, video, audio }

final class NetworkProxySettings {
  NetworkProxySettings({required this.protocol, required this.host, required this.port, required Map<NetworkProxyTraffic, bool> enabled})
    : enabled = Map<NetworkProxyTraffic, bool>.unmodifiable(enabled);

  static final defaults = NetworkProxySettings(
    protocol: NetworkProxyProtocol.http,
    host: '127.0.0.1',
    port: 9000,
    enabled: <NetworkProxyTraffic, bool>{
      NetworkProxyTraffic.source: false,
      NetworkProxyTraffic.novel: false,
      NetworkProxyTraffic.manga: false,
      NetworkProxyTraffic.video: false,
      NetworkProxyTraffic.audio: false,
    },
  );

  final NetworkProxyProtocol protocol;
  final String host;
  final int port;
  final Map<NetworkProxyTraffic, bool> enabled;

  bool isEnabled(NetworkProxyTraffic traffic) => enabled[traffic] ?? false;

  String get uri => '${protocol.name}://$host:$port';

  Map<String, Object?> toSettingValue() => <String, Object?>{
    'protocol': protocol.name,
    'host': host,
    'port': port,
    'enabled': <String, Object?>{for (final traffic in NetworkProxyTraffic.values) traffic.name: isEnabled(traffic)},
  };

  static NetworkProxySettings fromSettingValue(Map<String, Object?> value) {
    try {
      final protocol = NetworkProxyProtocol.values.byName(value['protocol']! as String);
      final rawEnabled = value['enabled']! as Map<Object?, Object?>;
      return NetworkProxySettings(
        protocol: protocol,
        host: value['host']! as String,
        port: value['port']! as int,
        enabled: <NetworkProxyTraffic, bool>{for (final traffic in NetworkProxyTraffic.values) traffic: rawEnabled[traffic.name] as bool},
      );
    } on Object {
      return defaults;
    }
  }
}

final networkProxySettingsProvider = Provider<NetworkProxySettings>((Ref ref) {
  final settings = ref.watch(appSettingsProvider);
  ref.watch(appSettingsStatusProvider);
  return NetworkProxySettings.fromSettingValue(settings.get(AppSettingKeys.networkProxyPreferences));
});

Future<void> saveNetworkProxySettings(AppSettingsManager settings, NetworkProxySettings value) =>
    settings.set(AppSettingKeys.networkProxyPreferences, value.toSettingValue());
