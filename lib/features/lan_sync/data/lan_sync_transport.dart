/// 局域网同步 v2 前台传输实现。
///
/// 职责：
/// - 提供发现、配对、有界控制帧和原样二进制 artifact 流。
/// - 在握手阶段明确拒绝不兼容协议版本。
///
/// 注意：连接、计时器和流必须在完成、失败或取消时释放。
/// - Android 的 Dart Socket 不支持 reusePort，发现套接字不得启用该选项。
///
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

part 'lan_sync_manifest_codec.dart';

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
  final int completedBytes;
  final int totalBytes;
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

final class LanSyncDiscoveryService {
  LanSyncDiscoveryService._(this._socket, this._controller);

  final RawDatagramSocket _socket;
  final StreamController<LanSyncPeer> _controller;
  final Map<String, DateTime> _seen = <String, DateTime>{};

  Stream<LanSyncPeer> get peers => _controller.stream;

  static Future<LanSyncDiscoveryService> start() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, lanSyncDiscoveryPort, reuseAddress: true);
    final controller = StreamController<LanSyncPeer>.broadcast();
    final service = LanSyncDiscoveryService._(socket, controller);
    socket.listen(service._onEvent, onError: (_) {});
    return service;
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _socket.receive()) != null) {
      try {
        final bytes = datagram!.data;
        if (bytes.length > 1024) continue;
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map || decoded['kind'] != 'mgread-lan-sync') continue;
        final version = decoded['protocolVersion'];
        final sessionId = decoded['sessionId'];
        final label = decoded['label'];
        final port = decoded['port'];
        final expiresAtRaw = decoded['expiresAtUtc'];
        if (version != lanSyncProtocolVersion ||
            sessionId is! String ||
            sessionId.isEmpty ||
            sessionId.length > 128 ||
            label is! String ||
            label.isEmpty ||
            label.length > 128 ||
            port is! int ||
            port < 1 ||
            port > 65535 ||
            expiresAtRaw is! String) {
          continue;
        }
        final expiresAt = DateTime.tryParse(expiresAtRaw)?.toUtc();
        if (expiresAt == null || !expiresAt.isAfter(DateTime.now().toUtc())) {
          continue;
        }
        final key = '$sessionId|${datagram.address.address}|$port';
        final last = _seen[key];
        final now = DateTime.now().toUtc();
        if (last != null && now.difference(last) < const Duration(seconds: 1)) {
          continue;
        }
        _seen[key] = now;
        _controller.add(
          LanSyncPeer(sessionId: sessionId, label: label, address: datagram.address.address, port: port, expiresAtUtc: expiresAt),
        );
      } on Object {
        // Discovery packets are untrusted and malformed packets are ignored.
      }
    }
  }

  Future<void> close() async {
    _socket.close();
    await _controller.close();
  }
}

final class LanSyncSenderService {
  LanSyncSenderService._({
    required this.sessionId,
    required this.manifest,
    required this.openPlugin,
    required this._server,
    required this._announcementSocket,
    required this._addresses,
  });

  final String sessionId;
  final LanSyncManifest manifest;
  final LanSyncPluginStreamOpener openPlugin;
  final ServerSocket _server;
  final RawDatagramSocket _announcementSocket;
  final List<String> _addresses;
  final StreamController<LanSyncSenderEvent> _events = StreamController<LanSyncSenderEvent>.broadcast();
  Timer? _announcementTimer;
  Timer? _expiryTimer;
  Socket? _activeSocket;
  bool _closed = false;

  Stream<LanSyncSenderEvent> get events => _events.stream;
  int get port => _server.port;
  List<String> get addresses => List.unmodifiable(_addresses);

  static Future<LanSyncSenderService> start({required LanSyncManifest manifest, required LanSyncPluginStreamOpener openPlugin}) async {
    final sessionId = _randomToken(18);
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final announcementSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    announcementSocket.broadcastEnabled = true;
    final addresses = await eligibleLanSyncAddresses();
    final service = LanSyncSenderService._(
      sessionId: sessionId,
      manifest: manifest,
      openPlugin: openPlugin,
      server: server,
      announcementSocket: announcementSocket,
      addresses: addresses,
    );
    service._start();
    return service;
  }

  void _start() {
    _events.add(LanSyncSenderReady(_addresses, _server.port));
    _announce();
    _announcementTimer = Timer.periodic(const Duration(seconds: 1), (_) => _announce());
    _expiryTimer = Timer(lanSyncSessionLifetime, () {
      _fail('lan_sync_session_expired');
    });
    _server.listen(_accept, onError: (_) => _fail('lan_sync_listen_failed'), cancelOnError: false);
  }

  void _announce() {
    if (_closed) return;
    final message = utf8.encode(
      jsonEncode(<String, Object?>{
        'kind': 'mgread-lan-sync',
        'protocolVersion': lanSyncProtocolVersion,
        'sessionId': sessionId,
        'label': Platform.isWindows ? 'Windows 设备' : 'Android 设备',
        'port': _server.port,
        'expiresAtUtc': DateTime.now().toUtc().add(lanSyncSessionLifetime).toIso8601String(),
      }),
    );
    try {
      _announcementSocket.send(message, InternetAddress('255.255.255.255'), lanSyncDiscoveryPort);
    } on Object {
      // Manual address entry remains available if broadcast is unavailable.
    }
  }

  Future<void> _accept(Socket socket) async {
    if (_closed || _activeSocket != null || !_isEligiblePeer(socket.remoteAddress)) {
      socket.destroy();
      return;
    }
    _activeSocket = socket;
    final connection = LanSyncFramedConnection(socket);
    try {
      final hello = await connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (hello['type'] == 'hello' && hello['protocolVersion'] != lanSyncProtocolVersion) {
        await connection.sendControl(<String, Object?>{'type': 'incompatible', 'protocolVersion': lanSyncProtocolVersion});
        throw const LanSyncTransportException('lan_sync_protocol_incompatible');
      }
      if (hello['type'] != 'hello' || hello['sessionId'] != sessionId || !_isNonce(hello['clientNonce'])) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      final serverNonce = _randomToken(16);
      final code = _pairingCode('$sessionId|${hello['clientNonce']}|$serverNonce');
      await connection.sendControl(<String, Object?>{'type': 'pair', 'serverNonce': serverNonce, 'code': code});
      _events.add(LanSyncSenderPairing(code));
      final remoteConfirm = await connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (remoteConfirm['type'] != 'confirm' || remoteConfirm['code'] != code) {
        throw const LanSyncTransportException('lan_sync_pairing_rejected');
      }
      await connection.sendControl(<String, Object?>{'type': 'confirmed', 'code': code});
      await connection.sendControl(<String, Object?>{'type': 'manifest', 'value': manifest.toJson()}, maxBytes: lanSyncMaxManifestBytes);
      final selection = await connection.readControl();
      if (selection['type'] != 'selection' || selection['pluginIds'] is! List) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      final rawSelection = selection['pluginIds']! as List<Object?>;
      final rawShelfSelection = selection['shelfItemIds'];
      if (rawShelfSelection != null && rawShelfSelection is! List) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      if (rawSelection.length > lanSyncMaxPluginCount || rawSelection.any((value) => value is! String)) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      final selectedShelfItemIds = rawShelfSelection == null
          ? <String>{for (final item in manifest.shelfItems) item.identity}
          : <String>{
              for (final value in rawShelfSelection as List<Object?>)
                if (value is String) value,
            };
      if (rawShelfSelection is List &&
          (rawShelfSelection.length > lanSyncMaxShelfItemCount ||
              rawShelfSelection.any((value) => value is! String) ||
              selectedShelfItemIds.length != rawShelfSelection.length)) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      final selectedIds = <String>{for (final value in rawSelection) value! as String};
      if (selectedIds.length != rawSelection.length) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      final availableShelfItemIds = <String>{for (final item in manifest.shelfItems) item.identity};
      if (!availableShelfItemIds.containsAll(selectedShelfItemIds)) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      final selected = manifest.plugins.where((item) => item.transferable && selectedIds.contains(item.id)).toList(growable: false);
      if (selected.length != selectedIds.length) {
        throw const LanSyncTransportException('lan_sync_selection_invalid');
      }
      var completedBytes = 0;
      final totalBytes = selected.fold<int>(0, (sum, item) => sum + item.bytes);
      for (final plugin in selected) {
        await connection.sendControl(<String, Object?>{'type': 'pluginBegin', 'plugin': plugin.toJson()});
        var pluginBytes = 0;
        await for (final rawChunk in await openPlugin(plugin)) {
          if (rawChunk.isEmpty) continue;
          for (var offset = 0; offset < rawChunk.length;) {
            final end = min(rawChunk.length, offset + lanSyncPluginRelayChunkBytes);
            final chunk = Uint8List.fromList(rawChunk.sublist(offset, end));
            await connection.sendBinary(chunk);
            pluginBytes += chunk.length;
            completedBytes += chunk.length;
            _events.add(LanSyncSenderProgress(completedBytes, totalBytes));
            offset = end;
          }
        }
        if (pluginBytes != plugin.bytes) {
          throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
        }
        await connection.sendControl(<String, Object?>{'type': 'pluginEnd', 'pluginId': plugin.id, 'bytes': pluginBytes});
      }
      await connection.sendControl(<String, Object?>{'type': 'transferComplete', 'pluginCount': selected.length, 'bytes': completedBytes});
      _events.add(const LanSyncSenderDone());
      await close();
    } on TimeoutException catch (error, stackTrace) {
      await connection.close();
      _activeSocket = null;
      if (!_closed) {
        _events.add(LanSyncSenderFailed('lan_sync_timeout', error: error, stackTrace: stackTrace));
      }
    } on LanSyncTransportException catch (error, stackTrace) {
      await connection.close();
      _activeSocket = null;
      if (!_closed) _events.add(LanSyncSenderFailed(error.code, error: error, stackTrace: stackTrace));
    } on Object catch (error, stackTrace) {
      await connection.close();
      _activeSocket = null;
      if (!_closed) {
        _events.add(LanSyncSenderFailed('lan_sync_transport_failed', error: error, stackTrace: stackTrace));
      }
    }
  }

  void _fail(String code) {
    if (_closed) return;
    _events.add(LanSyncSenderFailed(code));
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _announcementTimer?.cancel();
    _expiryTimer?.cancel();
    _announcementSocket.close();
    _activeSocket?.destroy();
    await _server.close();
    await _events.close();
  }
}

final class LanSyncReceiverConnection {
  LanSyncReceiverConnection._(this._connection, this.pairingCode, this.peer);

  final LanSyncFramedConnection _connection;
  final String pairingCode;
  final LanSyncPeer peer;
  bool _closed = false;
  LanSyncManifest? _manifest;

  static Future<LanSyncReceiverConnection> connect(LanSyncPeer peer, {Duration timeout = lanSyncHandshakeTimeout}) async {
    if (!isLanSyncPrivateIpv4(peer.address)) {
      throw const LanSyncTransportException('lan_sync_address_not_private');
    }
    LanSyncFramedConnection? connection;
    try {
      final socket = await Socket.connect(peer.address, peer.port, timeout: timeout);
      connection = LanSyncFramedConnection(socket);
      final clientNonce = _randomToken(16);
      await connection.sendControl(<String, Object?>{
        'type': 'hello',
        'protocolVersion': lanSyncProtocolVersion,
        'sessionId': peer.sessionId,
        'clientNonce': clientNonce,
      });
      final pair = await connection.readControl().timeout(timeout);
      if (pair['type'] == 'incompatible') {
        throw const LanSyncTransportException('lan_sync_protocol_incompatible');
      }
      if (pair['type'] != 'pair' || !_isNonce(pair['serverNonce']) || pair['code'] is! String) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      final expected = _pairingCode('${peer.sessionId}|$clientNonce|${pair['serverNonce']}');
      if (pair['code'] != expected) {
        throw const LanSyncTransportException('lan_sync_pairing_invalid');
      }
      return LanSyncReceiverConnection._(connection, expected, peer);
    } on Object {
      await connection?.close();
      rethrow;
    }
  }

  static Future<LanSyncReceiverConnection> connectAny(Iterable<LanSyncPeer> peers) async {
    final candidates = <LanSyncPeer>[];
    final endpoints = <String>{};
    for (final peer in peers) {
      if (endpoints.add('${peer.address}:${peer.port}')) candidates.add(peer);
    }
    if (candidates.isEmpty || candidates.length > lanSyncMaxCandidateAddresses) {
      throw const LanSyncTransportException('lan_sync_connect_failed');
    }

    final result = Completer<LanSyncReceiverConnection>();
    var remaining = candidates.length;
    LanSyncTransportException? incompatibleProtocol;
    for (final peer in candidates) {
      unawaited(() async {
        try {
          final connection = await connect(peer, timeout: const Duration(seconds: 5));
          if (!result.isCompleted) {
            result.complete(connection);
          } else {
            await connection.close();
          }
        } on Object catch (error) {
          if (error is LanSyncTransportException && error.code == 'lan_sync_protocol_incompatible') {
            incompatibleProtocol = error;
          }
          remaining--;
          if (remaining == 0 && !result.isCompleted) {
            result.completeError(incompatibleProtocol ?? const LanSyncTransportException('lan_sync_connect_failed'));
          }
        }
      }());
    }
    return result.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () => throw const LanSyncTransportException('lan_sync_connect_failed'),
    );
  }

  Future<LanSyncManifest> confirmAndReadManifest() async {
    await _connection.sendControl(<String, Object?>{'type': 'confirm', 'code': pairingCode});
    final confirmed = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
    if (confirmed['type'] != 'confirmed' || confirmed['code'] != pairingCode) {
      throw const LanSyncTransportException('lan_sync_pairing_rejected');
    }
    final frame = await _connection.readControl(maxBytes: lanSyncMaxManifestBytes);
    final manifest = _decodeLanSyncManifestFrame(frame);
    _manifest = manifest;
    return manifest;
  }

  Future<void> receivePlugins({
    required Set<String> pluginIds,
    Set<String>? shelfItemIds,
    required Future<void> Function(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) importPlugin,
    void Function(int completedBytes, int totalBytes)? onProgress,
    void Function()? onPluginBytesReceived,
  }) async {
    final manifest = _manifest;
    if (manifest == null || pluginIds.length > lanSyncMaxPluginCount) {
      throw const LanSyncTransportException('lan_sync_selection_invalid');
    }
    final selectedShelfItemIds = shelfItemIds == null
        ? <String>{for (final item in manifest.shelfItems) item.identity}
        : Set<String>.of(shelfItemIds);
    final availableShelfItemIds = <String>{for (final item in manifest.shelfItems) item.identity};
    if (selectedShelfItemIds.length > lanSyncMaxShelfItemCount || !availableShelfItemIds.containsAll(selectedShelfItemIds)) {
      throw const LanSyncTransportException('lan_sync_selection_invalid');
    }
    final selectedById = <String, LanSyncPluginDescriptor>{
      for (final plugin in manifest.plugins)
        if (pluginIds.contains(plugin.id)) plugin.id: plugin,
    };
    if (selectedById.length != pluginIds.length || selectedById.values.any((plugin) => !plugin.transferable)) {
      throw const LanSyncTransportException('lan_sync_selection_invalid');
    }
    await _connection.sendControl(<String, Object?>{
      'type': 'selection',
      'pluginIds': pluginIds.toList(growable: false),
      'shelfItemIds': selectedShelfItemIds.toList(growable: false),
    });
    var completedBytes = 0;
    final totalBytes = selectedById.values.fold<int>(0, (sum, plugin) => sum + plugin.bytes);
    final receivedIds = <String>{};
    while (true) {
      final frame = await _connection.readFrame().timeout(lanSyncTransferIdleTimeout);
      if (frame case LanSyncControlFrame(:final value)) {
        switch (value['type']) {
          case 'transferComplete':
            if (receivedIds.length != pluginIds.length ||
                !receivedIds.containsAll(pluginIds) ||
                value['pluginCount'] != pluginIds.length ||
                value['bytes'] != completedBytes ||
                completedBytes != totalBytes) {
              throw const LanSyncTransportException('lan_sync_transfer_incomplete');
            }
            return;
          case 'pluginBegin':
            final raw = value['plugin'];
            if (raw is! Map) {
              throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
            }
            final plugin = LanSyncPluginDescriptor.fromJson(
              raw.map<String, Object?>((key, value) {
                if (key is! String) {
                  throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
                }
                return MapEntry(key, value);
              }),
            );
            if (!pluginIds.contains(plugin.id)) {
              throw const LanSyncTransportException('lan_sync_plugin_unexpected');
            }
            final expected = selectedById[plugin.id]!;
            if (!receivedIds.add(plugin.id) ||
                plugin.version != expected.version ||
                plugin.artifactFormat != expected.artifactFormat ||
                plugin.bytes != expected.bytes ||
                plugin.sha256 != expected.sha256 ||
                !plugin.transferable) {
              throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
            }
            final controller = StreamController<List<int>>();
            final importFuture = importPlugin(plugin, controller.stream);
            var pluginBytes = 0;
            while (pluginBytes < plugin.bytes) {
              final chunkFrame = await _connection.readFrame().timeout(lanSyncTransferIdleTimeout);
              if (chunkFrame is! LanSyncBinaryFrame) {
                await controller.close();
                throw const LanSyncTransportException('lan_sync_plugin_frame_invalid');
              }
              pluginBytes += chunkFrame.bytes.length;
              completedBytes += chunkFrame.bytes.length;
              if (pluginBytes > plugin.bytes) {
                await controller.close();
                throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
              }
              controller.add(chunkFrame.bytes);
              onProgress?.call(completedBytes, totalBytes);
            }
            onPluginBytesReceived?.call();
            // Do not wait for the local Runtime before draining pluginEnd. A
            // sender may be blocked flushing that frame while the receiver is
            // flushing the artifact to disk, which otherwise creates a TCP
            // back-pressure deadlock exactly at 100% network progress.
            final streamClosed = controller.close();
            final end = await _connection.readControl().timeout(lanSyncTransferIdleTimeout);
            if (end['type'] != 'pluginEnd' || end['pluginId'] != plugin.id || end['bytes'] != pluginBytes) {
              throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
            }
            await streamClosed.timeout(lanSyncTransferIdleTimeout);
            await importFuture.timeout(lanSyncTransferIdleTimeout);
          default:
            throw const LanSyncTransportException('lan_sync_frame_unexpected');
        }
      } else {
        throw const LanSyncTransportException('lan_sync_frame_unexpected');
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _connection.close();
  }
}

sealed class LanSyncFrame {
  const LanSyncFrame();
}

final class LanSyncControlFrame extends LanSyncFrame {
  const LanSyncControlFrame(this.value);
  final Map<String, Object?> value;
}

final class LanSyncBinaryFrame extends LanSyncFrame {
  const LanSyncBinaryFrame(this.bytes);
  final Uint8List bytes;
}

final class LanSyncFramedConnection {
  LanSyncFramedConnection(this._socket) : _iterator = StreamIterator(_socket);

  final Socket _socket;
  final StreamIterator<Uint8List> _iterator;
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;
  bool _closed = false;

  Future<void> sendControl(Map<String, Object?> value, {int maxBytes = lanSyncMaxControlFrameBytes}) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > maxBytes) {
      throw const LanSyncTransportException('lan_sync_control_too_large');
    }
    await _sendFrame(0, bytes);
  }

  Future<void> sendBinary(Uint8List bytes, {int maxBytes = lanSyncMaxBinaryChunkBytes}) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const LanSyncTransportException('lan_sync_binary_too_large');
    }
    await _sendFrame(1, bytes);
  }

  Future<void> _sendFrame(int kind, List<int> bytes) async {
    if (_closed) {
      throw const LanSyncTransportException('lan_sync_connection_closed');
    }
    final length = bytes.length + 1;
    final header = ByteData(4)..setUint32(0, length, Endian.big);
    _socket.add(header.buffer.asUint8List());
    _socket.add(<int>[kind]);
    _socket.add(bytes);
    await _socket.flush();
  }

  Future<Map<String, Object?>> readControl({int maxBytes = lanSyncMaxControlFrameBytes}) async {
    final frame = await readFrame(controlMaxBytes: maxBytes);
    if (frame is! LanSyncControlFrame) {
      throw const LanSyncTransportException('lan_sync_control_expected');
    }
    return frame.value;
  }

  Future<LanSyncFrame> readFrame({
    int binaryMaxBytes = lanSyncMaxBinaryChunkBytes,
    int controlMaxBytes = lanSyncMaxControlFrameBytes,
  }) async {
    final header = await _readExactly(4);
    final length = ByteData.sublistView(header).getUint32(0, Endian.big);
    final maxFrameBytes = max(controlMaxBytes, binaryMaxBytes) + 1;
    if (length < 2 || length > maxFrameBytes) {
      throw const LanSyncTransportException('lan_sync_frame_too_large');
    }
    final payload = await _readExactly(length);
    final kind = payload[0];
    final body = Uint8List.sublistView(payload, 1);
    if (kind == 1) {
      if (body.isEmpty || body.length > binaryMaxBytes) {
        throw const LanSyncTransportException('lan_sync_binary_too_large');
      }
      return LanSyncBinaryFrame(Uint8List.fromList(body));
    }
    if (kind != 0 || body.length > controlMaxBytes) {
      throw const LanSyncTransportException('lan_sync_control_invalid');
    }
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map) throw const FormatException();
      return LanSyncControlFrame(
        decoded.map<String, Object?>((key, value) {
          if (key is! String) throw const FormatException();
          return MapEntry(key, value);
        }),
      );
    } on Object {
      throw const LanSyncTransportException('lan_sync_control_invalid');
    }
  }

  Future<Uint8List> _readExactly(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_offset >= _buffer.length) {
        final hasNext = await _iterator.moveNext();
        if (!hasNext) {
          throw const LanSyncTransportException('lan_sync_disconnected');
        }
        _buffer = _iterator.current;
        _offset = 0;
      }
      final available = _buffer.length - _offset;
      final take = min(length - written, available);
      result.setRange(written, written + take, _buffer, _offset);
      _offset += take;
      written += take;
    }
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
    _socket.destroy();
  }
}

Future<List<String>> eligibleLanSyncAddresses() async {
  final candidates = <LanSyncNetworkAddress>[];
  for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
    for (final address in interface.addresses) {
      candidates.add(LanSyncNetworkAddress(interfaceName: interface.name, address: address.address));
    }
  }
  return selectLanSyncCandidateAddresses(candidates);
}

bool _isEligiblePeer(InternetAddress address) => address.type == InternetAddressType.IPv4 && isLanSyncPrivateIpv4(address.address);

final class LanSyncNetworkAddress {
  const LanSyncNetworkAddress({required this.interfaceName, required this.address});

  final String interfaceName;
  final String address;
}

List<String> selectLanSyncCandidateAddresses(Iterable<LanSyncNetworkAddress> candidates) {
  final result = <String>{};
  for (final candidate in candidates) {
    if (_isUsableLanInterface(candidate.interfaceName) && isLanSyncPrivateIpv4(candidate.address)) {
      result.add(candidate.address);
    }
  }
  final sorted = result.toList(growable: false)
    ..sort((left, right) {
      final rank = _addressRank(left).compareTo(_addressRank(right));
      return rank != 0 ? rank : left.compareTo(right);
    });
  return List.unmodifiable(sorted.take(lanSyncMaxCandidateAddresses));
}

bool _isUsableLanInterface(String name) {
  final normalized = name.toLowerCase();
  const excludedFragments = <String>[
    'vethernet',
    'virtual',
    'hyper-v',
    'wsl',
    'docker',
    'vmware',
    'virtualbox',
    'vbox',
    'tailscale',
    'zerotier',
    'wireguard',
    'wintun',
    'vpn',
    'loopback',
    'tunnel',
    'teredo',
    'isatap',
    '虚拟',
    '隧道',
  ];
  return !excludedFragments.any(normalized.contains);
}

int _addressRank(String address) => switch (address.split('.').first) {
  '192' => 0,
  '10' => 1,
  _ => 2,
};

String _randomToken(int bytes) {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(bytes, (_) => random.nextInt(256))).replaceAll('=', '');
}

bool _isNonce(Object? value) => value is String && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

String _pairingCode(String input) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return (hash % 1000000).toString().padLeft(6, '0');
}
