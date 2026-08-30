/// Flutter-owned direct proxy configuration for app HTTP clients.
///
/// Responsibilities:
/// - expose the user-configured upstream endpoint without a loopback adapter;
/// - configure Dart HTTP clients directly for HTTP, HTTPS and SOCKS5;
/// - keep Runtime-owned loopback resources on a direct local connection.
///
/// This owner never starts a server, rewrites process environment variables or
/// forwards Node.js traffic. Runtime consumers receive the upstream endpoint.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socks5_proxy/socks_client.dart';

import 'network_proxy_settings.dart';
import 'player_local_proxy_policy.dart';

final flutterNetworkProxyManagerProvider = Provider<FlutterNetworkProxyManager>((Ref ref) => FlutterNetworkProxyManager());

/// Samples persisted settings and keeps direct client configuration current.
final configuredFlutterNetworkProxyManagerProvider = Provider<FlutterNetworkProxyManager>((Ref ref) {
  ref.watch(configuredPlayerLocalProxyPolicyProvider);
  final manager = ref.watch(flutterNetworkProxyManagerProvider);
  manager.update(ref.watch(networkProxySettingsProvider));
  return manager;
});

final class FlutterNetworkProxyManager {
  NetworkProxySettings _settings = NetworkProxySettings.defaults;

  void update(NetworkProxySettings value) => _settings = value;

  /// Returns the actual user-configured upstream endpoint for [traffic].
  Uri? proxyUriFor(NetworkProxyTraffic traffic) {
    if (!_settings.isEnabled(traffic)) return null;
    return Uri(scheme: _settings.protocol.name, host: _settings.host, port: _settings.port);
  }

  /// Returns the HTTP-only endpoint understood by MediaKit/mpv.
  Uri? playerProxyUriFor(NetworkProxyTraffic traffic) {
    if (traffic != NetworkProxyTraffic.video && traffic != NetworkProxyTraffic.audio) {
      throw ArgumentError.value(traffic, 'traffic', 'A video or audio route is required.');
    }
    final proxy = proxyUriFor(traffic);
    return proxy?.scheme == 'http' ? proxy : null;
  }

  /// Creates an isolated Dart client that connects to the upstream directly.
  Future<HttpClient> createHttpClient(NetworkProxyTraffic traffic) async {
    final settings = _settings;
    if (!settings.isEnabled(traffic)) {
      return HttpClient()..findProxy = (_) => 'DIRECT';
    }
    return switch (settings.protocol) {
      NetworkProxyProtocol.http => _createHttpProxyClient(settings),
      NetworkProxyProtocol.https => _createHttpsProxyClient(settings),
      NetworkProxyProtocol.socks5 => await _createSocks5ProxyClient(settings),
    };
  }
}

HttpClient _createHttpProxyClient(NetworkProxySettings settings) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..findProxy = (target) => _isLoopbackTarget(target) ? 'DIRECT' : 'PROXY ${settings.host}:${settings.port}';

HttpClient _createHttpsProxyClient(NetworkProxySettings settings) {
  final client = _createHttpProxyClient(settings);
  client.connectionFactory = (target, proxyHost, proxyPort) {
    if (proxyHost == null) return Socket.startConnect(target.host, target.port);
    final connection = SecureSocket.connect(proxyHost, proxyPort ?? settings.port, timeout: const Duration(seconds: 15));
    return Future<ConnectionTask<Socket>>.value(ConnectionTask.fromSocket<Socket>(connection, () async => (await connection).destroy()));
  };
  return client;
}

Future<HttpClient> _createSocks5ProxyClient(NetworkProxySettings settings) async {
  final proxyAddress = await _resolve(settings.host);
  final proxies = <ProxySettings>[ProxySettings(proxyAddress, settings.port)];
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..findProxy = (_) => 'DIRECT';
  client.connectionFactory = (target, _, _) {
    if (_isLoopbackTarget(target)) return Socket.startConnect(target.host, target.port);
    final connection = SocksTCPClient.connect(proxies, InternetAddress(target.host, type: InternetAddressType.unix), target.port);
    return Future<ConnectionTask<Socket>>.value(ConnectionTask.fromSocket<Socket>(connection, () async => (await connection).destroy()));
  };
  return client;
}

bool _isLoopbackTarget(Uri target) {
  if (target.host.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(target.host)?.isLoopback ?? false;
}

Future<InternetAddress> _resolve(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return literal;
  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw SocketException('Proxy host could not be resolved: $host.');
  return addresses.first;
}
