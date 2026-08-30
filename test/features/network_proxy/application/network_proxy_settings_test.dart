import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  test('defaults to the configured endpoint with every direct route disabled', () {
    final value = NetworkProxySettings.defaults;

    expect(value.uri, 'http://127.0.0.1:9000');
    expect(value.useEnvironmentProxy, isFalse);
    expect(value.forcePlayerLocalProxy, isFalse);
    expect(NetworkProxyTraffic.values, <NetworkProxyTraffic>[
      NetworkProxyTraffic.sourceHttp,
      NetworkProxyTraffic.cover,
      NetworkProxyTraffic.manga,
      NetworkProxyTraffic.video,
      NetworkProxyTraffic.audio,
    ]);
    expect(NetworkProxyTraffic.values.every((traffic) => !value.isEnabled(traffic)), isTrue);
  });

  test('round trips the direct endpoint and remaining independent switches', () {
    final source = NetworkProxySettings(
      protocol: NetworkProxyProtocol.socks5,
      host: '10.0.0.2',
      port: 1080,
      useEnvironmentProxy: true,
      forcePlayerLocalProxy: true,
      enabled: <NetworkProxyTraffic, bool>{
        NetworkProxyTraffic.sourceHttp: true,
        NetworkProxyTraffic.cover: false,
        NetworkProxyTraffic.manga: true,
        NetworkProxyTraffic.video: true,
        NetworkProxyTraffic.audio: false,
      },
    );

    final restored = NetworkProxySettings.fromSettingValue(source.toSettingValue());

    expect(restored.uri, 'socks5://10.0.0.2:1080');
    expect(restored.useEnvironmentProxy, isTrue);
    expect(restored.forcePlayerLocalProxy, isTrue);
    expect(restored.shouldForcePlayerLocalProxy, isFalse);
    expect(restored.enabled, source.enabled);
  });

  test('forces the player loopback only for an enabled HTTP media route', () {
    final value = NetworkProxySettings(
      protocol: NetworkProxyProtocol.http,
      host: '127.0.0.1',
      port: 9000,
      forcePlayerLocalProxy: true,
      enabled: const <NetworkProxyTraffic, bool>{NetworkProxyTraffic.audio: true},
    );

    expect(value.shouldForcePlayerLocalProxy, isTrue);
  });

  test('production setting key accepts and persists the current five-route payload', () async {
    final store = FakeSettingsStore();
    final manager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await manager.initialize();
    addTearDown(manager.close);
    final value = NetworkProxySettings(
      protocol: NetworkProxyProtocol.https,
      host: 'proxy.example',
      port: 8443,
      useEnvironmentProxy: true,
      forcePlayerLocalProxy: true,
      enabled: <NetworkProxyTraffic, bool>{
        NetworkProxyTraffic.sourceHttp: true,
        NetworkProxyTraffic.cover: true,
        NetworkProxyTraffic.manga: false,
        NetworkProxyTraffic.video: true,
        NetworkProxyTraffic.audio: true,
      },
    );

    expect(() => AppSettingKeys.networkProxyPreferences.validateValue(value.toSettingValue()), returnsNormally);
    await saveNetworkProxySettings(manager, value);
    await manager.flush();

    final restored = NetworkProxySettings.fromSettingValue(manager.get(AppSettingKeys.networkProxyPreferences));
    expect(restored.enabled, value.enabled);
    expect(restored.useEnvironmentProxy, isTrue);
    expect(restored.forcePlayerLocalProxy, isTrue);
    expect(restored.shouldForcePlayerLocalProxy, isFalse);
  });

  test('decoder removes obsolete Runtime route and retains media routes from the six-route payload', () {
    final decoded = AppSettingKeys.networkProxyPreferences.decodeValue(<String, Object?>{
      'protocol': 'http',
      'host': '127.0.0.1',
      'port': 9000,
      'enabled': <String, Object?>{'runtime': true, 'sourceHttp': true, 'cover': false, 'manga': true, 'video': true, 'audio': true},
    });

    expect(decoded['enabled'], <String, Object?>{'sourceHttp': true, 'cover': false, 'manga': true, 'video': true, 'audio': true});
    expect(decoded['useEnvironmentProxy'], isFalse);
    expect(decoded['forcePlayerLocalProxy'], isFalse);
    expect(() => AppSettingKeys.networkProxyPreferences.validateValue(decoded), returnsNormally);
  });

  test('decoder projects older route documents onto direct consumers only', () {
    for (final enabled in <Map<String, Object?>>[
      <String, Object?>{'runtime': true, 'cover': true, 'manga': false, 'video': true, 'audio': false},
      <String, Object?>{'runtime': true, 'manga': true, 'video': false, 'audio': true},
      <String, Object?>{'source': true, 'novel': true, 'manga': true, 'video': true, 'audio': true},
    ]) {
      final decoded = AppSettingKeys.networkProxyPreferences.decodeValue(<String, Object?>{
        'protocol': 'http',
        'host': '127.0.0.1',
        'port': 9000,
        'enabled': enabled,
      });

      expect(decoded['enabled'], <String, Object?>{
        'sourceHttp': false,
        'cover': enabled['cover'] as bool? ?? false,
        'manga': enabled['manga'] as bool,
        'video': enabled['video'] as bool? ?? false,
        'audio': enabled['audio'] as bool? ?? false,
      });
      expect(decoded['useEnvironmentProxy'], isFalse);
      expect(decoded['forcePlayerLocalProxy'], isFalse);
      expect(() => AppSettingKeys.networkProxyPreferences.validateValue(decoded), returnsNormally);
    }
  });
}
