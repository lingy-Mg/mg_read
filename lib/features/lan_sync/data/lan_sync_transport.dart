/// 临时扫码同步的 HTTP 传输实现。
///
/// 二维码交付一次性端点；配对确认、manifest 和选择使用 JSON HTTP API，
/// 插件制品通过独立 GET 及标准 Range/ETag/If-Range 传输。最后一个制品响应
/// 完成后发送端主动关闭，不等待接收端回报本地导入结果。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mg_read/features/lan_sync/data/lan_sync_http_artifact.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_client.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

typedef LanSyncPluginStreamOpener = Future<Stream<List<int>>> Function(LanSyncPluginDescriptor plugin);

sealed class LanSyncSenderEvent {
  const LanSyncSenderEvent();
}

final class LanSyncSenderReady extends LanSyncSenderEvent {
  const LanSyncSenderReady(this.addresses, this.port);
  final List<String> addresses;
  final int port;
}

final class LanSyncSenderPairing extends LanSyncSenderEvent {
  const LanSyncSenderPairing(this.code);
  final String code;
}

final class LanSyncSenderProgress extends LanSyncSenderEvent {
  const LanSyncSenderProgress(this.completedBytes, this.totalBytes);
  final int completedBytes, totalBytes;
}

final class LanSyncSenderActivity extends LanSyncSenderEvent {
  const LanSyncSenderActivity(this.active);
  final bool active;
}

final class LanSyncSenderDone extends LanSyncSenderEvent {
  const LanSyncSenderDone();
}

final class LanSyncSenderFailed extends LanSyncSenderEvent {
  const LanSyncSenderFailed(this.code, {this.error, this.stackTrace});
  final String code;
  final Object? error;
  final StackTrace? stackTrace;
}

final class LanSyncTransportException implements Exception {
  const LanSyncTransportException(this.code, {this.reason});
  final String code;
  final String? reason;
  @override
  String toString() => reason == null ? 'LanSyncTransportException($code)' : 'LanSyncTransportException($code, reason: $reason)';
}

final class LanSyncSenderService {
  LanSyncSenderService._({
    required this.sessionId,
    required this.manifest,
    required this.openPlugin,
    required this._server,
    required this._addresses,
  });
  final String sessionId;
  final LanSyncManifest manifest;
  final LanSyncPluginStreamOpener openPlugin;
  final HttpServer _server;
  final List<String> _addresses;
  final StreamController<LanSyncSenderEvent> _events = StreamController<LanSyncSenderEvent>.broadcast();
  final Map<String, LanSyncHttpArtifact> _artifacts = {};
  final Set<String> _selectedPluginIds = <String>{};
  final Set<String> _servedPluginIds = <String>{};
  Timer? _expiryTimer;
  String? _pairingCode;
  bool _closed = false, _active = false, _completionStarted = false;
  int _sent = 0, _total = 0;
  Stream<LanSyncSenderEvent> get events => _events.stream;
  int get port => _server.port;
  List<String> get addresses => List.unmodifiable(_addresses);
  static Future<LanSyncSenderService> start({required LanSyncManifest manifest, required LanSyncPluginStreamOpener openPlugin}) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final result = LanSyncSenderService._(
      sessionId: _randomToken(18),
      manifest: manifest,
      openPlugin: openPlugin,
      server: server,
      addresses: await eligibleLanSyncAddresses(),
    );
    result._start();
    return result;
  }

  void _start() {
    _events.add(LanSyncSenderReady(_addresses, port));
    _server.listen(_handle, onError: (Object e, StackTrace s) => _fail('lan_sync_listen_failed', e, s));
    _expiryTimer = Timer(lanSyncSessionLifetime, () => _fail('lan_sync_session_expired'));
  }

  Future<void> _handle(HttpRequest request) async {
    var authenticated = false;
    try {
      if (!_eligiblePeer(request.connectionInfo?.remoteAddress)) {
        return await _respond(request.response, HttpStatus.forbidden, {'error': 'not_private'});
      }
      if (request.method == 'POST' && request.uri.path == '/v3/pair') {
        final body = await _jsonBody(request);
        if (body['sessionId'] != sessionId || !_validNonce(body['clientNonce'])) {
          throw const LanSyncTransportException('lan_sync_handshake_invalid');
        }
        final serverNonce = _randomToken(16);
        final code = _derivePairingCode('$sessionId|${body['clientNonce']}|$serverNonce');
        _pairingCode = code;
        _events.add(LanSyncSenderPairing(code));
        return await _respond(request.response, HttpStatus.ok, {'serverNonce': serverNonce, 'pairingCode': code});
      }
      if (request.headers.value('x-mgread-session') != _pairingCode) {
        return await _respond(request.response, HttpStatus.unauthorized, {'error': 'pairing_required'});
      }
      authenticated = true;
      if (request.method == 'POST' && request.uri.path == '/v3/manifest') {
        return await _respond(request.response, HttpStatus.ok, {'manifest': manifest.toJson()});
      }
      if (request.method == 'POST' && request.uri.path == '/v3/selection') {
        final body = await _jsonBody(request);
        final raw = body['pluginIds'];
        final shelf = body['shelfItemIds'];
        if (raw is! List || shelf is! List || raw.any((e) => e is! String) || shelf.any((e) => e is! String)) {
          throw const LanSyncTransportException('lan_sync_selection_invalid');
        }
        final ids = raw.cast<String>().toSet();
        final selected = manifest.plugins.where((p) => ids.contains(p.id)).toList();
        if (selected.length != ids.length) throw const LanSyncTransportException('lan_sync_selection_invalid');
        _setActive(true);
        _total = selected.fold(0, (n, p) => n + p.bytes);
        for (final plugin in selected) {
          final artifact = await LanSyncHttpArtifact.materialize(plugin, await openPlugin(plugin));
          _artifacts[plugin.id] = artifact;
        }
        _selectedPluginIds
          ..clear()
          ..addAll(selected.map((plugin) => plugin.id));
        await _respond(request.response, HttpStatus.ok, {'plugins': selected.map((p) => p.toJson()).toList()});
        if (selected.isEmpty) await _finishSending();
        return;
      }
      final parts = request.uri.pathSegments;
      if (request.method == 'GET' && parts.length == 3 && parts[0] == 'v3' && parts[1] == 'artifacts') {
        final artifact = _artifacts[Uri.decodeComponent(parts[2])];
        if (artifact == null) throw const LanSyncTransportException('lan_sync_plugin_unexpected');
        final completesArtifact = _requestCoversArtifact(request, artifact.descriptor.bytes, artifact.etag);
        await artifact.serve(request);
        if (completesArtifact && _servedPluginIds.add(artifact.descriptor.id)) {
          _sent += artifact.descriptor.bytes;
          _events.add(LanSyncSenderProgress(_sent, _total));
          if (_servedPluginIds.length == _selectedPluginIds.length) await _finishSending();
        }
        return;
      }
      return await _respond(request.response, HttpStatus.notFound, {'error': 'not_found'});
    } on Object catch (e, s) {
      if (authenticated) {
        _fail(e is LanSyncTransportException ? e.code : 'lan_sync_http_failed', e, s);
      }
      try {
        await _respond(request.response, HttpStatus.badRequest, {'error': e.toString()});
      } on Object {
        // The peer may disconnect before an error response is written.
      }
    }
  }

  void _setActive(bool value) {
    if (_active == value) return;
    _active = value;
    _events.add(LanSyncSenderActivity(value));
  }

  Future<void> _finishSending() async {
    if (_closed || _completionStarted) return;
    _completionStarted = true;
    _events.add(const LanSyncSenderDone());
    await close();
  }

  void _fail(String code, [Object? error, StackTrace? stack]) {
    if (_closed) return;
    _events.add(LanSyncSenderFailed(code, error: error, stackTrace: stack));
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _setActive(false);
    _expiryTimer?.cancel();
    for (final artifact in _artifacts.values) {
      await artifact.close();
    }
    _artifacts.clear();
    await _server.close(force: true);
    await _events.close();
  }
}

final class LanSyncReceiverConnection {
  LanSyncReceiverConnection._(this.pairingCode, this.peer, this._client, this._base);
  final String pairingCode;
  final LanSyncPeer peer;
  final HttpClient _client;
  final Uri _base;
  LanSyncManifest? _manifest;
  bool _closed = false;
  static Future<LanSyncReceiverConnection> connect(LanSyncPeer peer, {Duration timeout = lanSyncHandshakeTimeout}) async {
    if (!isLanSyncPrivateIpv4(peer.address)) throw const LanSyncTransportException('lan_sync_address_not_private');
    final client = createLanSyncHttpClient();
    try {
      final base = Uri.parse('http://${peer.address}:${peer.port}');
      final nonce = _randomToken(16);
      final result = await _request(client, base.resolve('/v3/pair'), {
        'sessionId': peer.sessionId,
        'clientNonce': nonce,
      }, null).timeout(timeout);
      final serverNonce = result['serverNonce'];
      final code = result['pairingCode'];
      final expected = _derivePairingCode('${peer.sessionId}|$nonce|$serverNonce');
      if (!_validNonce(serverNonce) || code != expected) throw const LanSyncTransportException('lan_sync_pairing_invalid');
      return LanSyncReceiverConnection._(expected, peer, client, base);
    } on Object {
      client.close(force: true);
      rethrow;
    }
  }

  static Future<LanSyncReceiverConnection> connectAny(Iterable<LanSyncPeer> peers) async {
    Object? last;
    for (final peer in peers.take(lanSyncMaxCandidateAddresses)) {
      try {
        return await connect(peer, timeout: const Duration(seconds: 5));
      } on Object catch (e) {
        last = e;
      }
    }
    throw last ?? const LanSyncTransportException('lan_sync_connect_failed');
  }

  Future<LanSyncManifest> confirmAndReadManifest() async {
    final result = await _request(_client, _base.resolve('/v3/manifest'), const {}, pairingCode);
    final raw = result['manifest'];
    if (raw is! Map) throw const LanSyncTransportException('lan_sync_manifest_invalid');
    final manifest = LanSyncManifest.fromJson(raw.map<String, Object?>((k, v) => MapEntry(k as String, v)));
    _manifest = manifest;
    return manifest;
  }

  Future<void> receivePlugins({
    required Set<String> pluginIds,
    Set<String>? shelfItemIds,
    required Future<void> Function(LanSyncPluginDescriptor, Stream<List<int>>) importPlugin,
    void Function(int, int)? onProgress,
    void Function(LanSyncPluginDescriptor, int, int)? onVerificationProgress,
    void Function(LanSyncPluginDescriptor, int, int)? onWriteProgress,
    void Function()? onPluginBytesReceived,
  }) async {
    final manifest = _manifest;
    if (manifest == null) throw const LanSyncTransportException('lan_sync_selection_invalid');
    final shelf = shelfItemIds ?? manifest.shelfItems.map((e) => e.identity).toSet();
    final result = await _request(_client, _base.resolve('/v3/selection'), {
      'pluginIds': pluginIds.toList(),
      'shelfItemIds': shelf.toList(),
    }, pairingCode);
    final raw = result['plugins'];
    if (raw is! List) throw const LanSyncTransportException('lan_sync_selection_invalid');
    final plugins = raw
        .map((e) => LanSyncPluginDescriptor.fromJson((e as Map).map<String, Object?>((k, v) => MapEntry(k as String, v))))
        .toList();
    var done = 0;
    final total = plugins.fold(0, (n, p) => n + p.bytes);
    for (final plugin in plugins) {
      final completedBeforePlugin = done;
      final stream = await const LanSyncHttpArtifactClient().download(
        _base.resolve('/v3/artifacts/${Uri.encodeComponent(plugin.id)}'),
        plugin,
        client: _client,
        authenticate: (request, _) => request.headers.set('x-mgread-session', pairingCode),
        onVerificationProgress: (completed, pluginTotal) {
          onVerificationProgress?.call(plugin, completedBeforePlugin + completed, total);
        },
      );
      await importPlugin(plugin, _reportImportProgress(stream, plugin, completedBeforePlugin, total, onWriteProgress));
      done += plugin.bytes;
      onProgress?.call(done, total);
      onPluginBytesReceived?.call();
    }
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

Stream<List<int>> _reportImportProgress(
  Stream<List<int>> source,
  LanSyncPluginDescriptor plugin,
  int completedBeforePlugin,
  int totalBytes,
  void Function(LanSyncPluginDescriptor, int, int)? onProgress,
) async* {
  var completed = 0;
  await for (final chunk in source) {
    completed += chunk.length;
    onProgress?.call(plugin, completedBeforePlugin + completed, totalBytes);
    yield chunk;
  }
}

Future<Map<String, Object?>> _request(
  HttpClient client,
  Uri uri,
  Map<String, Object?> body,
  String? code, {
  bool allowEmpty = false,
}) async {
  final bytes = utf8.encode(jsonEncode(body));
  final request = await client.postUrl(uri);
  if (code != null) request.headers.set('x-mgread-session', code);
  request.headers.contentType = ContentType.json;
  request.contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close();
  final text = await utf8.decodeStream(response);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw LanSyncTransportException('lan_sync_http_failed', reason: 'status_${response.statusCode}');
  }
  if (text.isEmpty && allowEmpty) return {};
  final raw = jsonDecode(text);
  if (raw is! Map) throw const LanSyncTransportException('lan_sync_control_invalid');
  return raw.map<String, Object?>((k, v) => MapEntry(k as String, v));
}

Future<Map<String, Object?>> _jsonBody(HttpRequest request) async {
  final bytes = await request.fold<List<int>>([], (a, b) {
    if (a.length + b.length > lanSyncMaxManifestBytes) throw const LanSyncTransportException('lan_sync_control_too_large');
    return a..addAll(b);
  });
  final raw = jsonDecode(utf8.decode(bytes));
  if (raw is! Map) throw const LanSyncTransportException('lan_sync_control_invalid');
  return raw.map<String, Object?>((k, v) => MapEntry(k as String, v));
}

Future<void> _respond(HttpResponse response, int status, Map<String, Object?>? value) async {
  response.statusCode = status;
  if (value == null) {
    response.contentLength = 0;
  } else {
    final bytes = utf8.encode(jsonEncode(value));
    response.headers.contentType = ContentType.json;
    response.contentLength = bytes.length;
    response.add(bytes);
  }
  await response.close();
}

bool _requestCoversArtifact(HttpRequest request, int bytes, String etag) {
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (range == null) return true;
  final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
  if (ifRange != null && ifRange != etag) return true;
  final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
  if (match == null) return false;
  final start = int.tryParse(match.group(1)!);
  if (start == null || start >= bytes) return false;
  final end = match.group(2);
  return end == null || end.isEmpty || int.tryParse(end) == bytes - 1;
}

Future<List<String>> eligibleLanSyncAddresses() async {
  final candidates = <LanSyncNetworkAddress>[];
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
    for (final a in i.addresses) {
      candidates.add(LanSyncNetworkAddress(interfaceName: i.name, address: a.address));
    }
  }
  return selectLanSyncCandidateAddresses(candidates);
}

bool _eligiblePeer(InternetAddress? a) => a != null && a.type == InternetAddressType.IPv4 && isLanSyncPrivateIpv4(a.address);

final class LanSyncNetworkAddress {
  const LanSyncNetworkAddress({required this.interfaceName, required this.address});
  final String interfaceName, address;
}

List<String> selectLanSyncCandidateAddresses(Iterable<LanSyncNetworkAddress> candidates) {
  final result = <String>{};
  for (final c in candidates) {
    if (_usable(c.interfaceName) && isLanSyncPrivateIpv4(c.address)) result.add(c.address);
  }
  final sorted = result.toList()
    ..sort((a, b) {
      final rank = _rank(a).compareTo(_rank(b));
      return rank != 0 ? rank : a.compareTo(b);
    });
  return List.unmodifiable(sorted.take(lanSyncMaxCandidateAddresses));
}

bool _usable(String name) {
  final n = name.toLowerCase();
  return ![
    'loopback',
    'virtual',
    'vmware',
    'hyper-v',
    'vethernet',
    'docker',
    'wsl',
    'bluetooth',
    'tunnel',
    'tailscale',
    'zerotier',
  ].any(n.contains);
}

int _rank(String address) => address.startsWith('192.168.')
    ? 0
    : address.startsWith('10.')
    ? 1
    : 2;
bool _validNonce(Object? v) => v is String && v.length >= 20 && v.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v);
String _randomToken(int n) {
  final r = Random.secure();
  return base64Url.encode(List<int>.generate(n, (_) => r.nextInt(256))).replaceAll('=', '');
}

String _derivePairingCode(String seed) {
  var hash = 0;
  for (final unit in utf8.encode(seed)) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return (hash % 1000000).toString().padLeft(6, '0');
}
