/// 已配对设备的动态发现、认证连接与双向同步协议。
///
/// 职责：
/// - 广播稳定设备 ID 和本次前台端口，IP 始终取自收到的数据包。
/// - 使用逐设备共享密钥建立认证加密会话，并按双方策略同步插件和书架。
/// - 支持自动双向同步与接收端主动“只拉取一次”。
///
/// 注意：
/// - 广播不包含密钥、书名、插件名或持久地址。
/// - 删除不传播；书架冲突沿用 smartMerge，开发书源冲突由 Runtime 计划明确跳过。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_secure_connection.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

const int pairedSyncProtocolVersion = 1;
const int pairedSyncDiscoveryPort = 47232;
const Duration pairedSyncPeerLifetime = Duration(seconds: 8);

final class PairedSyncEndpoint {
  const PairedSyncEndpoint({
    required this.address,
    required this.deviceId,
    required this.expiresAtUtc,
    required this.label,
    required this.port,
  });

  final String address;
  final String deviceId;
  final DateTime expiresAtUtc;
  final String label;
  final int port;
}

final class PairedSyncRunSummary {
  const PairedSyncRunSummary({
    required this.receivedBooks,
    required this.receivedPlugins,
    required this.sentBooks,
    required this.sentPlugins,
    required this.developmentConflicts,
  });

  const PairedSyncRunSummary.empty() : receivedBooks = 0, receivedPlugins = 0, sentBooks = 0, sentPlugins = 0, developmentConflicts = 0;

  final int receivedBooks;
  final int receivedPlugins;
  final int sentBooks;
  final int sentPlugins;
  final int developmentConflicts;
}

final class PairedSyncHost {
  PairedSyncHost._({
    required this.identity,
    required this._server,
    required this._socket,
    required this._devices,
    required this._identityStore,
    required this._onIncoming,
  });

  final LocalDeviceIdentity identity;
  final ServerSocket _server;
  final RawDatagramSocket _socket;
  final PairedDeviceRepository _devices;
  final DeviceIdentityStore _identityStore;
  final Future<void> Function(PairedSyncServerSession session) _onIncoming;
  final StreamController<PairedSyncEndpoint> _endpoints = StreamController<PairedSyncEndpoint>.broadcast();
  final Set<Socket> _connections = <Socket>{};
  Timer? _announcer;
  bool _closed = false;

  Stream<PairedSyncEndpoint> get endpoints => _endpoints.stream;
  int get port => _server.port;

  static Future<PairedSyncHost> start({
    required LocalDeviceIdentity identity,
    required PairedDeviceRepository devices,
    required DeviceIdentityStore identityStore,
    required Future<void> Function(PairedSyncServerSession session) onIncoming,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, pairedSyncDiscoveryPort, reuseAddress: true);
      socket.broadcastEnabled = true;
      final host = PairedSyncHost._(
        identity: identity,
        server: server,
        socket: socket,
        devices: devices,
        identityStore: identityStore,
        onIncoming: onIncoming,
      );
      host._start();
      return host;
    } on Object {
      socket?.close();
      await server.close();
      rethrow;
    }
  }

  void _start() {
    _server.listen(_accept, onError: (_) => unawaited(close()), cancelOnError: false);
    _socket.listen(_onDatagram, onError: (_) {}, cancelOnError: false);
    _announce();
    _announcer = Timer.periodic(const Duration(seconds: 2), (_) => _announce());
  }

  void _announce() {
    if (_closed) return;
    final bytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'kind': 'mgread-paired-sync',
        'protocolVersion': pairedSyncProtocolVersion,
        'deviceId': identity.deviceId,
        'label': identity.label,
        'port': _server.port,
      }),
    );
    try {
      _socket.send(bytes, InternetAddress('255.255.255.255'), pairedSyncDiscoveryPort);
    } on Object {
      // 下一次周期广播会重试；已知 endpoint 仍可继续当前会话。
    }
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _closed) return;
    Datagram? datagram;
    while ((datagram = _socket.receive()) != null) {
      final packet = datagram!;
      try {
        if (!isLanSyncPrivateIpv4(packet.address.address)) continue;
        final raw = jsonDecode(utf8.decode(packet.data));
        if (raw is! Map || raw['kind'] != 'mgread-paired-sync' || raw['protocolVersion'] != pairedSyncProtocolVersion) {
          continue;
        }
        final deviceId = raw['deviceId'];
        final label = raw['label'];
        final port = raw['port'];
        if (deviceId is! String ||
            deviceId == identity.deviceId ||
            !isValidPairedDeviceId(deviceId) ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 128 ||
            port is! int ||
            port < 1 ||
            port > 65535) {
          continue;
        }
        _endpoints.add(
          PairedSyncEndpoint(
            address: packet.address.address,
            deviceId: deviceId,
            expiresAtUtc: DateTime.now().toUtc().add(pairedSyncPeerLifetime),
            label: label,
            port: port,
          ),
        );
      } on Object {
        // 未认证广播不可信，格式错误直接忽略。
      }
    }
  }

  Future<void> _accept(Socket socket) async {
    if (_closed || _connections.length >= 4 || !_eligiblePeer(socket.remoteAddress)) {
      socket.destroy();
      return;
    }
    _connections.add(socket);
    LanSyncFramedConnection? raw;
    PairedSecureConnection? secure;
    try {
      raw = LanSyncFramedConnection(socket);
      final hello = await raw.readControl().timeout(lanSyncHandshakeTimeout);
      final peerDeviceId = hello['deviceId'];
      final clientNonce = hello['clientNonce'];
      if (hello['type'] != 'pairedHello' ||
          hello['protocolVersion'] != pairedSyncProtocolVersion ||
          hello['targetDeviceId'] != identity.deviceId ||
          peerDeviceId is! String ||
          !isValidPairedDeviceId(peerDeviceId) ||
          !_validNonce(clientNonce)) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      final peer = await _devices.read(peerDeviceId);
      final secret = await _identityStore.readPeerSecret(peerDeviceId);
      if (peer == null || secret == null) {
        throw const LanSyncTransportException('lan_sync_peer_not_paired');
      }
      final serverNonce = _randomToken(16);
      await raw.sendControl(<String, Object?>{
        'type': 'pairedChallenge',
        'protocolVersion': pairedSyncProtocolVersion,
        'serverNonce': serverNonce,
      });
      secure = await PairedSecureConnection.server(
        raw: raw,
        sharedSecret: secret,
        clientNonce: clientNonce! as String,
        serverNonce: serverNonce,
      );
      await secure.sendControl(<String, Object?>{'type': 'pairedReady', 'deviceId': identity.deviceId, 'label': identity.label});
      final session = PairedSyncServerSession._(connection: secure, peer: peer);
      secure = null;
      await _onIncoming(session);
    } on Object {
      await (secure?.close() ?? raw?.close() ?? Future<void>.value());
    } finally {
      _connections.remove(socket);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _announcer?.cancel();
    _socket.close();
    for (final socket in _connections.toList(growable: false)) {
      socket.destroy();
    }
    _connections.clear();
    await _server.close();
    await _endpoints.close();
  }
}

final class PairedSyncClientSession {
  PairedSyncClientSession._({required this.peer, required this._connection});

  final PairedDevice peer;
  final PairedSecureConnection _connection;

  static Future<PairedSyncClientSession> connectAny({
    required Iterable<PairedSyncEndpoint> endpoints,
    required LocalDeviceIdentity identity,
    required PairedDevice peer,
    required List<int> sharedSecret,
  }) async {
    final candidates = endpoints.where((item) => item.deviceId == peer.deviceId).toList(growable: false);
    if (candidates.isEmpty) throw const LanSyncTransportException('lan_sync_peer_offline');
    final result = Completer<PairedSyncClientSession>();
    var remaining = candidates.length;
    for (final endpoint in candidates) {
      unawaited(() async {
        try {
          final session = await _connect(endpoint, identity, peer, sharedSecret);
          if (result.isCompleted) {
            await session.close();
          } else {
            result.complete(session);
          }
        } on Object catch (error, stackTrace) {
          remaining--;
          if (remaining == 0 && !result.isCompleted) result.completeError(error, stackTrace);
        }
      }());
    }
    return result.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw const LanSyncTransportException('lan_sync_connect_failed'),
    );
  }

  static Future<PairedSyncClientSession> _connect(
    PairedSyncEndpoint endpoint,
    LocalDeviceIdentity identity,
    PairedDevice peer,
    List<int> sharedSecret,
  ) async {
    if (!isLanSyncPrivateIpv4(endpoint.address)) {
      throw const LanSyncTransportException('lan_sync_address_not_private');
    }
    LanSyncFramedConnection? raw;
    PairedSecureConnection? secure;
    try {
      final socket = await Socket.connect(endpoint.address, endpoint.port, timeout: const Duration(seconds: 5));
      raw = LanSyncFramedConnection(socket);
      final clientNonce = _randomToken(16);
      await raw.sendControl(<String, Object?>{
        'type': 'pairedHello',
        'protocolVersion': pairedSyncProtocolVersion,
        'deviceId': identity.deviceId,
        'targetDeviceId': peer.deviceId,
        'clientNonce': clientNonce,
      });
      final challenge = await raw.readControl().timeout(lanSyncHandshakeTimeout);
      final serverNonce = challenge['serverNonce'];
      if (challenge['type'] != 'pairedChallenge' ||
          challenge['protocolVersion'] != pairedSyncProtocolVersion ||
          !_validNonce(serverNonce)) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      secure = await PairedSecureConnection.client(
        raw: raw,
        sharedSecret: sharedSecret,
        clientNonce: clientNonce,
        serverNonce: serverNonce! as String,
      );
      final ready = await secure.readControl().timeout(lanSyncHandshakeTimeout);
      if (ready['type'] != 'pairedReady' || ready['deviceId'] != peer.deviceId) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      return PairedSyncClientSession._(peer: peer, connection: secure);
    } on Object {
      await (secure?.close() ?? raw?.close() ?? Future<void>.value());
      rethrow;
    }
  }

  Future<PairedSyncRunSummary> run({required LanSyncGateway gateway, required bool pullOnly}) async {
    try {
      final localPolicy = _WirePolicy.fromDevice(peer, pullOnly: pullOnly);
      await _connection.sendControl(<String, Object?>{'type': 'syncRequest', ...localPolicy.toJson()});
      final ready = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (ready['type'] == 'syncBusy') throw const LanSyncTransportException('lan_sync_peer_busy');
      if (ready['type'] != 'syncReady') throw const LanSyncTransportException('lan_sync_handshake_invalid');
      final remotePolicy = _WirePolicy.fromJson(ready);

      final localManifest = _filterManifest(
        await gateway.createManifest(),
        plugins: localPolicy.canSend && localPolicy.syncPlugins && remotePolicy.canReceive && remotePolicy.syncPlugins,
        shelf: localPolicy.canSend && localPolicy.syncBookshelf && remotePolicy.canReceive && remotePolicy.syncBookshelf,
      );
      await _sendManifest(_connection, localManifest);
      final remoteManifest = await _readManifest(_connection);
      final receivePlan = await _planImport(gateway, remoteManifest);
      await _sendSelection(_connection, receivePlan.selection);
      final sendSelection = await _readSelection(_connection, localManifest);

      final received = await _receivePayload(_connection, gateway, remoteManifest, receivePlan);
      await _connection.sendControl(<String, Object?>{'type': 'receiveApplied', ...received.toJson()});
      final reverseReady = await _connection.readControl().timeout(lanSyncTransferIdleTimeout);
      if (reverseReady['type'] != 'reverseReady') throw const LanSyncTransportException('lan_sync_frame_unexpected');
      await _sendPayload(_connection, gateway, localManifest, sendSelection);
      final remoteApplied = _AppliedSummary.fromJson(
        await _connection.readControl().timeout(lanSyncTransferIdleTimeout),
        expectedType: 'receiveApplied',
      );
      await _connection.sendControl(<String, Object?>{'type': 'sessionComplete'});
      final complete = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (complete['type'] != 'sessionComplete') throw const LanSyncTransportException('lan_sync_frame_unexpected');
      return PairedSyncRunSummary(
        receivedBooks: received.books,
        receivedPlugins: received.plugins,
        sentBooks: remoteApplied.books,
        sentPlugins: remoteApplied.plugins,
        developmentConflicts: receivePlan.developmentConflicts + remoteApplied.developmentConflicts,
      );
    } finally {
      await close();
    }
  }

  Future<void> close() => _connection.close();
}

final class PairedSyncServerSession {
  PairedSyncServerSession._({required this.peer, required this._connection});

  final PairedDevice peer;
  final PairedSecureConnection _connection;

  Future<void> rejectBusy() async {
    try {
      await _connection.sendControl(<String, Object?>{'type': 'syncBusy'});
    } finally {
      await close();
    }
  }

  Future<PairedSyncRunSummary> run({required LanSyncGateway gateway}) async {
    try {
      final request = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (request['type'] != 'syncRequest') throw const LanSyncTransportException('lan_sync_handshake_invalid');
      final remotePolicy = _WirePolicy.fromJson(request);
      final localPolicy = _WirePolicy.fromDevice(peer);
      await _connection.sendControl(<String, Object?>{'type': 'syncReady', ...localPolicy.toJson()});

      final remoteManifest = await _readManifest(_connection);
      final localManifest = _filterManifest(
        await gateway.createManifest(),
        plugins: localPolicy.canSend && localPolicy.syncPlugins && remotePolicy.canReceive && remotePolicy.syncPlugins,
        shelf: localPolicy.canSend && localPolicy.syncBookshelf && remotePolicy.canReceive && remotePolicy.syncBookshelf,
      );
      await _sendManifest(_connection, localManifest);
      final sendSelection = await _readSelection(_connection, localManifest);
      final receivePlan = await _planImport(gateway, remoteManifest);
      await _sendSelection(_connection, receivePlan.selection);

      await _sendPayload(_connection, gateway, localManifest, sendSelection);
      final remoteApplied = _AppliedSummary.fromJson(
        await _connection.readControl().timeout(lanSyncTransferIdleTimeout),
        expectedType: 'receiveApplied',
      );
      await _connection.sendControl(<String, Object?>{'type': 'reverseReady'});
      final received = await _receivePayload(_connection, gateway, remoteManifest, receivePlan);
      await _connection.sendControl(<String, Object?>{'type': 'receiveApplied', ...received.toJson()});
      final complete = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (complete['type'] != 'sessionComplete') throw const LanSyncTransportException('lan_sync_frame_unexpected');
      await _connection.sendControl(<String, Object?>{'type': 'sessionComplete'});
      return PairedSyncRunSummary(
        receivedBooks: received.books,
        receivedPlugins: received.plugins,
        sentBooks: remoteApplied.books,
        sentPlugins: remoteApplied.plugins,
        developmentConflicts: receivePlan.developmentConflicts + remoteApplied.developmentConflicts,
      );
    } finally {
      await close();
    }
  }

  Future<void> close() => _connection.close();
}

final class _WirePolicy {
  const _WirePolicy({required this.canReceive, required this.canSend, required this.syncBookshelf, required this.syncPlugins});

  final bool canReceive;
  final bool canSend;
  final bool syncBookshelf;
  final bool syncPlugins;

  factory _WirePolicy.fromDevice(PairedDevice device, {bool pullOnly = false}) => _WirePolicy(
    canReceive: device.canReceive,
    canSend: device.canSend && !pullOnly,
    syncBookshelf: device.syncBookshelf,
    syncPlugins: device.syncPlugins,
  );

  factory _WirePolicy.fromJson(Map<String, Object?> json) {
    final values = <Object?>[json['canReceive'], json['canSend'], json['syncBookshelf'], json['syncPlugins']];
    if (values.any((value) => value is! bool)) throw const LanSyncTransportException('lan_sync_policy_invalid');
    return _WirePolicy(
      canReceive: json['canReceive']! as bool,
      canSend: json['canSend']! as bool,
      syncBookshelf: json['syncBookshelf']! as bool,
      syncPlugins: json['syncPlugins']! as bool,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'canReceive': canReceive,
    'canSend': canSend,
    'syncBookshelf': syncBookshelf,
    'syncPlugins': syncPlugins,
  };
}

final class _Selection {
  const _Selection({required this.pluginIds, required this.shelfItemIds});

  final Set<String> pluginIds;
  final Set<String> shelfItemIds;
}

final class _ImportPlan {
  const _ImportPlan({required this.developmentConflicts, required this.preview, required this.selection});

  final int developmentConflicts;
  final LanSyncImportPreview? preview;
  final _Selection selection;
}

final class _AppliedSummary {
  const _AppliedSummary({required this.books, required this.developmentConflicts, required this.plugins});

  const _AppliedSummary.empty({this.developmentConflicts = 0}) : books = 0, plugins = 0;

  final int books;
  final int developmentConflicts;
  final int plugins;

  Map<String, Object?> toJson() => <String, Object?>{'books': books, 'developmentConflicts': developmentConflicts, 'plugins': plugins};

  factory _AppliedSummary.fromJson(Map<String, Object?> json, {required String expectedType}) {
    final books = json['books'];
    final conflicts = json['developmentConflicts'];
    final plugins = json['plugins'];
    if (json['type'] != expectedType ||
        books is! int ||
        books < 0 ||
        books > lanSyncMaxShelfItemCount ||
        conflicts is! int ||
        conflicts < 0 ||
        conflicts > lanSyncMaxPluginCount ||
        plugins is! int ||
        plugins < 0 ||
        plugins > lanSyncMaxPluginCount) {
      throw const LanSyncTransportException('lan_sync_result_invalid');
    }
    return _AppliedSummary(books: books, developmentConflicts: conflicts, plugins: plugins);
  }
}

Future<_ImportPlan> _planImport(LanSyncGateway gateway, LanSyncManifest manifest) async {
  if (manifest.plugins.isEmpty && manifest.shelfItems.isEmpty) {
    return const _ImportPlan(
      developmentConflicts: 0,
      preview: null,
      selection: _Selection(pluginIds: <String>{}, shelfItemIds: <String>{}),
    );
  }
  final preview = await gateway.previewImport(manifest);
  return _ImportPlan(
    developmentConflicts: preview.pluginPlans.values.where((state) => state == LanSyncPluginPlanState.developmentConflict).length,
    preview: preview,
    selection: _Selection(pluginIds: preview.recommendedPluginIds, shelfItemIds: preview.selectedShelfItemIds),
  );
}

LanSyncManifest _filterManifest(LanSyncManifest source, {required bool plugins, required bool shelf}) => LanSyncManifest(
  plugins: plugins ? source.plugins : const <LanSyncPluginDescriptor>[],
  shelfItems: shelf ? source.shelfItems : const <LanSyncShelfItem>[],
  skippedShelfItems: shelf ? source.skippedShelfItems : 0,
);

Future<void> _sendManifest(PairedSecureConnection connection, LanSyncManifest manifest) =>
    connection.sendControl(<String, Object?>{'type': 'manifest', 'value': manifest.toJson()}, maxBytes: lanSyncMaxManifestBytes);

Future<LanSyncManifest> _readManifest(PairedSecureConnection connection) async {
  final frame = await connection.readControl(maxBytes: lanSyncMaxManifestBytes).timeout(lanSyncTransferIdleTimeout);
  final value = frame['value'];
  if (frame['type'] != 'manifest' || value is! Map) throw const LanSyncTransportException('lan_sync_manifest_invalid');
  try {
    return LanSyncManifest.fromJson(_stringMap(value));
  } on FormatException {
    throw const LanSyncTransportException('lan_sync_manifest_invalid');
  }
}

Future<void> _sendSelection(PairedSecureConnection connection, _Selection selection) => connection.sendControl(<String, Object?>{
  'type': 'selection',
  'pluginIds': selection.pluginIds.toList(growable: false),
  'shelfItemIds': selection.shelfItemIds.toList(growable: false),
});

Future<_Selection> _readSelection(PairedSecureConnection connection, LanSyncManifest manifest) async {
  final frame = await connection.readControl().timeout(lanSyncTransferIdleTimeout);
  final rawPlugins = frame['pluginIds'];
  final rawShelf = frame['shelfItemIds'];
  if (frame['type'] != 'selection' || rawPlugins is! List || rawShelf is! List) {
    throw const LanSyncTransportException('lan_sync_selection_invalid');
  }
  if (rawPlugins.length > lanSyncMaxPluginCount ||
      rawShelf.length > lanSyncMaxShelfItemCount ||
      rawPlugins.any((value) => value is! String) ||
      rawShelf.any((value) => value is! String)) {
    throw const LanSyncTransportException('lan_sync_selection_invalid');
  }
  final plugins = rawPlugins.cast<String>().toSet();
  final shelf = rawShelf.cast<String>().toSet();
  final availablePlugins = <String>{for (final item in manifest.plugins.where((item) => item.transferable)) item.id};
  final availableShelf = <String>{for (final item in manifest.shelfItems) item.identity};
  if (plugins.length != rawPlugins.length ||
      shelf.length != rawShelf.length ||
      !availablePlugins.containsAll(plugins) ||
      !availableShelf.containsAll(shelf)) {
    throw const LanSyncTransportException('lan_sync_selection_invalid');
  }
  return _Selection(pluginIds: plugins, shelfItemIds: shelf);
}

Future<void> _sendPayload(PairedSecureConnection connection, LanSyncGateway gateway, LanSyncManifest manifest, _Selection selection) async {
  final selected = manifest.plugins.where((item) => selection.pluginIds.contains(item.id)).toList(growable: false);
  var completedBytes = 0;
  for (final plugin in selected) {
    await connection.sendControl(<String, Object?>{'type': 'pluginBegin', 'plugin': plugin.toJson()});
    var pluginBytes = 0;
    await for (final rawChunk in await gateway.openPluginArchive(plugin)) {
      for (var offset = 0; offset < rawChunk.length;) {
        final end = min(rawChunk.length, offset + lanSyncPluginRelayChunkBytes);
        final chunk = Uint8List.fromList(rawChunk.sublist(offset, end));
        if (chunk.isNotEmpty) await connection.sendBinary(chunk);
        pluginBytes += chunk.length;
        completedBytes += chunk.length;
        offset = end;
      }
    }
    if (pluginBytes != plugin.bytes) throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
    await connection.sendControl(<String, Object?>{'type': 'pluginEnd', 'pluginId': plugin.id, 'bytes': pluginBytes});
  }
  await connection.sendControl(<String, Object?>{'type': 'transferComplete', 'pluginCount': selected.length, 'bytes': completedBytes});
}

Future<_AppliedSummary> _receivePayload(
  PairedSecureConnection connection,
  LanSyncGateway gateway,
  LanSyncManifest manifest,
  _ImportPlan plan,
) async {
  final selection = plan.selection;
  final selectedById = <String, LanSyncPluginDescriptor>{
    for (final plugin in manifest.plugins)
      if (selection.pluginIds.contains(plugin.id)) plugin.id: plugin,
  };
  await gateway.preparePluginImports(selectedById.values.toList(growable: false));
  var completedBytes = 0;
  final totalBytes = selectedById.values.fold<int>(0, (sum, plugin) => sum + plugin.bytes);
  final receivedIds = <String>{};
  try {
    while (true) {
      final frame = await connection.readFrame().timeout(lanSyncTransferIdleTimeout);
      if (frame is! LanSyncControlFrame) throw const LanSyncTransportException('lan_sync_frame_unexpected');
      final value = frame.value;
      if (value['type'] == 'transferComplete') {
        if (receivedIds.length != selection.pluginIds.length ||
            !receivedIds.containsAll(selection.pluginIds) ||
            value['pluginCount'] != selection.pluginIds.length ||
            value['bytes'] != completedBytes ||
            completedBytes != totalBytes) {
          throw const LanSyncTransportException('lan_sync_transfer_incomplete');
        }
        break;
      }
      if (value['type'] != 'pluginBegin' || value['plugin'] is! Map) {
        throw const LanSyncTransportException('lan_sync_frame_unexpected');
      }
      final plugin = LanSyncPluginDescriptor.fromJson(_stringMap(value['plugin']! as Map));
      final expected = selectedById[plugin.id];
      if (expected == null || !receivedIds.add(plugin.id) || !_samePlugin(plugin, expected)) {
        throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
      }
      final controller = StreamController<List<int>>();
      final import = gateway.importPluginArchive(plugin, controller.stream);
      var pluginBytes = 0;
      while (pluginBytes < plugin.bytes) {
        final chunk = await connection.readFrame().timeout(lanSyncTransferIdleTimeout);
        if (chunk is! LanSyncBinaryFrame) {
          await controller.close();
          throw const LanSyncTransportException('lan_sync_plugin_frame_invalid');
        }
        pluginBytes += chunk.bytes.length;
        completedBytes += chunk.bytes.length;
        if (pluginBytes > plugin.bytes) {
          await controller.close();
          throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
        }
        controller.add(chunk.bytes);
      }
      final streamClosed = controller.close();
      final end = await connection.readControl().timeout(lanSyncTransferIdleTimeout);
      if (end['type'] != 'pluginEnd' || end['pluginId'] != plugin.id || end['bytes'] != pluginBytes) {
        throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
      }
      await streamClosed.timeout(lanSyncTransferIdleTimeout);
      await import.timeout(lanSyncTransferIdleTimeout);
    }
    if (plan.preview == null) return _AppliedSummary.empty(developmentConflicts: plan.developmentConflicts);
    final pluginResult = await gateway.finishPluginImports();
    final selectedManifest = selection.shelfItemIds.length == manifest.shelfItems.length
        ? manifest
        : manifest.selectShelfItems(selection.shelfItemIds);
    final result = await gateway.applyImport(
      manifest: selectedManifest,
      conflictChoices: <String, LanSyncConflictChoice>{
        for (final conflict in plan.preview!.conflicts) conflict.identity: LanSyncConflictChoice.smartMerge,
      },
      availablePluginIds: pluginResult.availablePluginIds,
      pluginResult: pluginResult,
    );
    return _AppliedSummary(
      books: result.added + result.updated,
      developmentConflicts: plan.developmentConflicts,
      plugins: result.pluginInstalled,
    );
  } on Object {
    await gateway.cancelPluginImports();
    rethrow;
  }
}

bool _samePlugin(LanSyncPluginDescriptor left, LanSyncPluginDescriptor right) =>
    left.id == right.id &&
    left.version == right.version &&
    left.bytes == right.bytes &&
    left.artifactFormat == right.artifactFormat &&
    left.developmentFingerprint == right.developmentFingerprint &&
    left.developmentRevision == right.developmentRevision &&
    left.provenance == right.provenance &&
    left.sha256 == right.sha256 &&
    left.transferable;

Map<String, Object?> _stringMap(Map<dynamic, dynamic> value) => value.map<String, Object?>((key, value) {
  if (key is! String) throw const LanSyncTransportException('lan_sync_control_invalid');
  return MapEntry(key, value);
});

bool _eligiblePeer(InternetAddress address) => address.type == InternetAddressType.IPv4 && isLanSyncPrivateIpv4(address.address);

bool _validNonce(Object? value) =>
    value is String && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

String _randomToken(int length) {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(length, (_) => random.nextInt(256), growable: false)).replaceAll('=', '');
}
