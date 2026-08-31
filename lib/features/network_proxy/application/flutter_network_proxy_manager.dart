/// Flutter-owned system-default and custom proxy routing for app HTTP clients.
///
/// Responsibilities:
/// - inherit the platform proxy when a traffic class has no custom override;
/// - expose the user-configured upstream endpoint without a loopback adapter;
/// - configure Dart HTTP clients directly for HTTP, HTTPS and SOCKS5;
/// - keep Runtime-owned loopback resources on a direct local connection.
///
/// This owner never starts a server, rewrites process environment variables or
/// forwards Node.js traffic. Runtime consumers receive only resolved endpoints.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:socks5_proxy/socks_client.dart';

import 'network_proxy_settings.dart';
import 'player_local_proxy_policy.dart';

typedef SystemProxyEnvironmentLoader = Future<Map<String, String>> Function();

final flutterNetworkProxyManagerProvider = Provider<FlutterNetworkProxyManager>((Ref ref) => FlutterNetworkProxyManager());

/// Samples persisted settings and keeps direct client configuration current.
final configuredFlutterNetworkProxyManagerProvider = Provider<FlutterNetworkProxyManager>((Ref ref) {
  ref.watch(configuredPlayerLocalProxyPolicyProvider);
  final manager = ref.watch(flutterNetworkProxyManagerProvider);
  manager.update(ref.watch(networkProxySettingsProvider));
  return manager;
});

final class FlutterNetworkProxyManager {
  FlutterNetworkProxyManager({SystemProxyEnvironmentLoader? systemProxyEnvironmentLoader})
    : _systemProxyEnvironmentLoader = systemProxyEnvironmentLoader ?? readSystemProxyEnvironment;

  final SystemProxyEnvironmentLoader _systemProxyEnvironmentLoader;
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

  /// Resolves the platform proxy for an ordinary HTTP or HTTPS target.
  Future<Uri?> systemProxyUriFor(Uri target) async {
    final route = _systemProxyRoute(target, await _systemProxyEnvironmentLoader());
    if (!route.startsWith('PROXY ')) return null;
    final endpoint = route.substring('PROXY '.length).trim();
    final uri = Uri.tryParse(endpoint.contains('://') ? endpoint : 'http://$endpoint');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    return uri;
  }

  /// Returns the explicit Runtime source override, or Android's system route.
  /// Windows Runtime inherits its full environment map at process startup so
  /// per-scheme proxy and NO_PROXY behavior remain intact there.
  Future<Uri?> runtimeSourceProxyUri() async {
    final custom = proxyUriFor(NetworkProxyTraffic.sourceHttp);
    if (custom != null || !Platform.isAndroid) return custom;
    return systemProxyUriFor(Uri.parse('https://system-proxy.invalid'));
  }

  /// Creates an isolated Dart client using the custom route or system default.
  Future<HttpClient> createHttpClient(NetworkProxyTraffic traffic) async {
    final settings = _settings;
    if (!settings.isEnabled(traffic)) {
      return _createSystemProxyHttpClient(await _systemProxyEnvironmentLoader());
    }
    return switch (settings.protocol) {
      NetworkProxyProtocol.http => _createHttpProxyClient(settings),
      NetworkProxyProtocol.https => _createHttpsProxyClient(settings),
      NetworkProxyProtocol.socks5 => await _createSocks5ProxyClient(settings),
    };
  }
}

/// Installs the platform proxy baseline for otherwise-unowned Flutter clients.
Future<void> installSystemProxyHttpOverrides({SystemProxyEnvironmentLoader loader = readSystemProxyEnvironment}) async {
  HttpOverrides.global = _SystemProxyHttpOverrides(await loader());
}

final class _SystemProxyHttpOverrides extends HttpOverrides {
  _SystemProxyHttpOverrides(this.environment);

  final Map<String, String> environment;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (target) => _systemProxyRoute(target, environment);
    return client;
  }
}

HttpClient _createSystemProxyHttpClient(Map<String, String> environment) =>
    HttpClient()..findProxy = (target) => _systemProxyRoute(target, environment);

String _systemProxyRoute(Uri target, Map<String, String> environment) =>
    _isLoopbackTarget(target) ? 'DIRECT' : HttpClient.findProxyFromEnvironment(target, environment: environment);

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
