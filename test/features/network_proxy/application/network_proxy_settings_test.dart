import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

void main() {
  test('defaults to the requested local HTTP endpoint with all routes direct', () {
    final value = NetworkProxySettings.defaults;

    expect(value.uri, 'http://127.0.0.1:9000');
    expect(NetworkProxyTraffic.values.every((traffic) => !value.isEnabled(traffic)), isTrue);
  });

  test('round trips the endpoint and independent routing switches', () {
    final source = NetworkProxySettings(
      protocol: NetworkProxyProtocol.socks5,
      host: '10.0.0.2',
      port: 1080,
      enabled: <NetworkProxyTraffic, bool>{
        NetworkProxyTraffic.source: true,
        NetworkProxyTraffic.novel: false,
        NetworkProxyTraffic.manga: true,
        NetworkProxyTraffic.video: false,
        NetworkProxyTraffic.audio: true,
      },
    );

    final restored = NetworkProxySettings.fromSettingValue(source.toSettingValue());

    expect(restored.uri, 'socks5://10.0.0.2:1080');
    expect(restored.isEnabled(NetworkProxyTraffic.source), isTrue);
    expect(restored.isEnabled(NetworkProxyTraffic.novel), isFalse);
    expect(restored.isEnabled(NetworkProxyTraffic.manga), isTrue);
    expect(restored.isEnabled(NetworkProxyTraffic.video), isFalse);
    expect(restored.isEnabled(NetworkProxyTraffic.audio), isTrue);
  });
}
