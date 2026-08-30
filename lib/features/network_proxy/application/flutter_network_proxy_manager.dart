/// Flutter-owned selective proxy router used by app HTTP and media transports.
///
/// Responsibilities:
/// - Keep one loopback forward proxy endpoint stable for active Flutter clients.
/// - Route each new connection through the latest credential-free app setting.
/// - Adapt SOCKS5 to the HTTP proxy interface expected by MediaKit.
///
/// Notes:
/// - This service never records request metadata, payloads, or credentials.
/// - It does not set process environment variables and never configures Node.js.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socks5_proxy/socks_client.dart';

import 'network_proxy_settings.dart';

final flutterNetworkProxyManagerProvider = Provider<FlutterNetworkProxyManager>((Ref ref) {
  final manager = FlutterNetworkProxyManager();
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

/// Samples persisted settings and keeps the process-local router current.
final configuredFlutterNetworkProxyManagerProvider = Provider<FlutterNetworkProxyManager>((Ref ref) {
  final manager = ref.watch(flutterNetworkProxyManagerProvider);
  manager.update(ref.watch(networkProxySettingsProvider));
  return manager;
});

final class FlutterNetworkProxyManager {
  NetworkProxySettings _settings = NetworkProxySettings.defaults;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requests;
  Future<HttpServer>? _starting;
  bool _closed = false;

  /// Applies settings synchronously; existing tunnels finish on their old route.
  void update(NetworkProxySettings value) {
    if (_closed) throw StateError('Flutter proxy manager is closed.');
    _settings = value;
  }

  /// Returns the local HTTP adapter MediaKit and Dart clients can consume.
  Future<Uri?> proxyUriFor(NetworkProxyTraffic traffic) async {
    if (!_settings.isEnabled(traffic)) return null;
    final server = await _ensureServer();
    return Uri(scheme: 'http', host: InternetAddress.loopbackIPv4.address, port: server.port);
  }

  /// Creates an isolated client whose selected traffic is explicit, never ambient.
  Future<HttpClient> createHttpClient(NetworkProxyTraffic traffic) async {
    final proxy = await proxyUriFor(traffic);
    return HttpClient()..findProxy = proxy == null ? (_) => 'DIRECT' : (_) => 'PROXY ${proxy.host}:${proxy.port}';
  }

  Future<HttpServer> _ensureServer() async {
    final running = _server;
    if (running != null) return running;
    final pending = _starting;
    if (pending != null) return pending;
    if (_closed) throw StateError('Flutter proxy manager is closed.');
    final operation = HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
      if (_closed) {
        unawaited(server.close(force: true));
        throw StateError('Flutter proxy manager is closed.');
      }
      _server = server;
      _requests = server.listen(_handleRequest, onError: (_) {}, cancelOnError: false);
      return server;
    });
    _starting = operation;
    try {
      return await operation;
    } finally {
      _starting = null;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method.toUpperCase() == 'CONNECT') {
        await _handleConnect(request, _settings);
      } else {
        await _forwardHttp(request, _settings);
      }
    } on Object {
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..reasonPhrase = 'Proxy connection failed';
        await request.response.close();
      } on Object {
        // The client may already own or have closed the detached socket.
      }
    }
  }

  Future<void> _forwardHttp(HttpRequest incoming, NetworkProxySettings settings) async {
    final target = _targetUri(incoming);
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const HttpException('Unsupported proxy target scheme.');
    }
    final client = await _upstreamHttpClient(settings);
    try {
      final outgoing = await client.openUrl(incoming.method, target);
      _copyHeaders(incoming.headers, outgoing.headers, request: true);
      await outgoing.addStream(incoming);
      final upstream = await outgoing.close();
      incoming.response.statusCode = upstream.statusCode;
      incoming.response.reasonPhrase = upstream.reasonPhrase;
      _copyHeaders(upstream.headers, incoming.response.headers, request: false);
      if (upstream.statusCode == HttpStatus.switchingProtocols) {
        final downstreamSocket = await incoming.response.detachSocket();
        final upstreamSocket = await upstream.detachSocket();
        _relaySockets(downstreamSocket, upstreamSocket);
        return;
      }
      await incoming.response.addStream(upstream);
      await incoming.response.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handleConnect(HttpRequest incoming, NetworkProxySettings settings) async {
    final target = _connectTarget(incoming);
    final upstream = await _openTunnel(settings, target.$1, target.$2);
    incoming.response
      ..statusCode = HttpStatus.ok
      ..reasonPhrase = 'Connection Established';
    final downstream = await incoming.response.detachSocket();
    _relayTunnel(downstream, upstream);
  }

  Future<HttpClient> _upstreamHttpClient(NetworkProxySettings settings) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (settings.protocol == NetworkProxyProtocol.socks5) {
      final address = await _resolve(settings.host);
      SocksTCPClient.assignToHttpClient(client, <ProxySettings>[ProxySettings(address, settings.port)]);
      client.findProxy = (_) => 'DIRECT';
    } else {
      client.findProxy = (_) => 'PROXY ${settings.host}:${settings.port}';
      if (settings.protocol == NetworkProxyProtocol.https) {
        client.connectionFactory = (_, proxyHost, proxyPort) {
          late final Future<SecureSocket> connection;
          connection = SecureSocket.connect(proxyHost ?? settings.host, proxyPort ?? settings.port, timeout: const Duration(seconds: 15));
          return Future<ConnectionTask<Socket>>.value(
            ConnectionTask.fromSocket<Socket>(connection, () async => (await connection).destroy()),
          );
        };
      }
    }
    return client;
  }

  Future<_ProxyTunnel> _openTunnel(NetworkProxySettings settings, String host, int port) async {
    if (settings.protocol == NetworkProxyProtocol.socks5) {
      final proxyAddress = await _resolve(settings.host);
      final socket = await SocksTCPClient.connect(
        <ProxySettings>[ProxySettings(proxyAddress, settings.port)],
        InternetAddress(host, type: InternetAddressType.unix),
        port,
      );
      return _ProxyTunnel(socket, socket);
    }
    final Socket proxy = settings.protocol == NetworkProxyProtocol.https
        ? await SecureSocket.connect(settings.host, settings.port, timeout: const Duration(seconds: 15))
        : await Socket.connect(settings.host, settings.port, timeout: const Duration(seconds: 15));
    proxy.write('CONNECT $host:$port HTTP/1.1\r\nHost: $host:$port\r\nProxy-Connection: Keep-Alive\r\n\r\n');
    await proxy.flush();
    final _ConnectResponse result;
    try {
      result = await _readConnectResponse(proxy);
    } on Object {
      proxy.destroy();
      rethrow;
    }
    if (result.statusCode != HttpStatus.ok) {
      proxy.destroy();
      throw HttpException('Upstream proxy rejected CONNECT with ${result.statusCode}.');
    }
    return _ProxyTunnel(proxy, result.stream);
  }

  Future<_ConnectResponse> _readConnectResponse(Socket socket) async {
    final bytes = <int>[];
    final completer = Completer<_ConnectResponse>();
    final body = StreamController<List<int>>();
    var connected = false;
    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        if (connected) {
          body.add(chunk);
          return;
        }
        bytes.addAll(chunk);
        if (bytes.length > 32 * 1024) {
          completer.completeError(const HttpException('Upstream proxy response is too large.'));
          unawaited(subscription.cancel());
          return;
        }
        final boundary = _headerBoundary(bytes);
        if (boundary < 0) return;
        final statusLine = String.fromCharCodes(bytes.take(boundary)).split('\r\n').first;
        final match = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(statusLine);
        if (match == null) {
          completer.completeError(const HttpException('Invalid upstream proxy response.'));
          unawaited(subscription.cancel());
          return;
        }
        connected = true;
        completer.complete(_ConnectResponse(int.parse(match.group(1)!), body.stream));
        final trailing = bytes.skip(boundary + 4).toList(growable: false);
        if (trailing.isNotEmpty) body.add(trailing);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
        body.addError(error, stackTrace);
        unawaited(body.close());
      },
      onDone: () {
        if (!completer.isCompleted) completer.completeError(const HttpException('Incomplete upstream proxy response.'));
        unawaited(body.close());
      },
      cancelOnError: false,
    );
    body.onCancel = subscription.cancel;
    return completer.future;
  }

  void _relaySockets(Socket first, Socket second) => _relay(first, second, second);

  void _relayTunnel(Socket downstream, _ProxyTunnel upstream) => _relay(downstream, upstream.socket, upstream.stream);

  void _relay(Socket downstream, Socket upstreamSink, Stream<List<int>> upstreamStream) {
    var closed = false;
    void closeBoth() {
      if (closed) return;
      closed = true;
      downstream.destroy();
      upstreamSink.destroy();
    }

    unawaited(downstream.addStream(upstreamStream).then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(closeBoth));
    unawaited(upstreamSink.addStream(downstream).then<void>((_) {}, onError: (Object _, StackTrace _) {}).whenComplete(closeBoth));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _requests?.cancel();
    await _server?.close(force: true);
    _requests = null;
    _server = null;
  }
}

final class _ConnectResponse {
  const _ConnectResponse(this.statusCode, this.stream);

  final int statusCode;
  final Stream<List<int>> stream;
}

final class _ProxyTunnel {
  const _ProxyTunnel(this.socket, this.stream);

  final Socket socket;
  final Stream<List<int>> stream;
}

Uri _targetUri(HttpRequest request) {
  if (request.uri.hasScheme) return request.uri;
  final host = request.headers.value(HttpHeaders.hostHeader);
  if (host == null || host.isEmpty) throw const HttpException('Proxy request has no host.');
  return Uri.parse('http://$host').resolveUri(request.uri);
}

(String, int) _connectTarget(HttpRequest request) {
  final authority = request.uri.authority.isNotEmpty ? request.uri.authority : request.uri.path;
  final parsed = Uri.parse('http://$authority');
  if (parsed.host.isEmpty) throw const HttpException('CONNECT target is invalid.');
  return (parsed.host, parsed.hasPort ? parsed.port : 443);
}

Future<InternetAddress> _resolve(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return literal;
  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw SocketException('Proxy host could not be resolved: $host.');
  return addresses.first;
}

int _headerBoundary(List<int> bytes) {
  for (var index = 0; index + 3 < bytes.length; index++) {
    if (bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10) return index;
  }
  return -1;
}

void _copyHeaders(HttpHeaders source, HttpHeaders target, {required bool request}) {
  const omitted = <String>{'proxy-authorization', 'proxy-connection', 'transfer-encoding'};
  source.forEach((name, values) {
    if (omitted.contains(name.toLowerCase())) return;
    if (request && name.toLowerCase() == HttpHeaders.hostHeader) return;
    target.set(name, values, preserveHeaderCase: true);
  });
}
