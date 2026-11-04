/// 已配对设备的 HTTP 发现、请求认证和双向同步。
///
/// HTTP v4 业务接口把书架元信息、阅读进度、本地 TXT/EPUB 原件、单插件制品与
/// 用户主动触发的 App 包建模为独立任务；文件任务最多三个并发，GET 支持 Range。
/// 逐设备配对密钥只用于 HMAC 请求与 UDP 唤醒认证。
/// 原生来源导出按已配对接收端平台裁剪归档，制品描述符记录裁剪后大小和摘要。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_peer_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/app_transfer_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_artifact.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_client.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/native_platform_artifact.dart';
import 'local_document_http_artifact.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

part 'paired_sync_wake.dart';
part 'paired_sync_http_session.dart';
part 'paired_sync_models.dart';
part 'paired_app_update.dart';

const int pairedSyncProtocolVersion = 4;
const int pairedSyncDiscoveryPort = 47232;
const Duration pairedSyncPeerLifetime = Duration(seconds: 8);
const Duration _sessionLifetime = Duration(minutes: 10);

final class PairedSyncHost {
  PairedSyncHost._({
    required this.identity,
    required this.discoveryPort,
    required this._server,
    required this._socket,
    required this._devices,
    required this._identityStore,
    required this._onIncoming,
    required this._onWakeRequest,
    required this._onWakeFailure,
    required this._announcementInterval,
    required this._advertisedPeerLifetime,
    required this._canAnnounce,
    required this._appUpdates,
    required this._peerService,
  });

  final LocalDeviceIdentity identity;
  final int discoveryPort;
  final HttpServer _server;
  final RawDatagramSocket _socket;
  final PairedDeviceRepository _devices;
  final DeviceIdentityStore _identityStore;
  final Future<void> Function(PairedSyncServerSession) _onIncoming;
  final Future<void> Function(PairedSyncWakeRequest)? _onWakeRequest;
  final Future<void> Function(PairedSyncWakeFailure)? _onWakeFailure;
  final Duration _announcementInterval;
  final Duration _advertisedPeerLifetime;
  final Future<bool> Function()? _canAnnounce;
  final AppUpdateService? _appUpdates;
  final LanPeerService? _peerService;
  final StreamController<PairedSyncEndpoint> _endpoints = StreamController<PairedSyncEndpoint>.broadcast();
  final Map<String, _HttpExchange> _sessions = <String, _HttpExchange>{};
  final Map<String, _HostedAppPackage> _appPackages = <String, _HostedAppPackage>{};
  final Map<String, DateTime> _acceptedWakeRequests = <String, DateTime>{};
  final Map<String, int> _requestNonces = <String, int>{};
  Timer? _announcer;
  bool _announcementInFlight = false;
  bool _closed = false;

  Stream<PairedSyncEndpoint> get endpoints => _endpoints.stream;
  int get port => _server.port;

  static Future<PairedSyncHost> start({
    required LocalDeviceIdentity identity,
    required PairedDeviceRepository devices,
    required DeviceIdentityStore identityStore,
    required Future<void> Function(PairedSyncServerSession) onIncoming,
    Future<void> Function(PairedSyncWakeRequest)? onWakeRequest,
    Future<void> Function(PairedSyncWakeFailure)? onWakeFailure,
    Duration announcementInterval = const Duration(seconds: 2),
    Duration advertisedPeerLifetime = pairedSyncPeerLifetime,
    Future<bool> Function()? canAnnounce,
    int discoveryPort = pairedSyncDiscoveryPort,
    AppUpdateService? appUpdates,
    LanPeerService? peerService,
  }) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true, reusePort: Platform.isMacOS);
      socket.broadcastEnabled = true;
      final host = PairedSyncHost._(
        identity: identity,
        discoveryPort: socket.port,
        server: server,
        socket: socket,
        devices: devices,
        identityStore: identityStore,
        onIncoming: onIncoming,
        onWakeRequest: onWakeRequest,
        onWakeFailure: onWakeFailure,
        announcementInterval: announcementInterval,
        advertisedPeerLifetime: advertisedPeerLifetime,
        canAnnounce: canAnnounce,
        appUpdates: appUpdates,
        peerService: peerService,
      );
      host._start();
      peerService?.hostChanged(server.port);
      return host;
    } on Object {
      socket?.close();
      await server.close(force: true);
      rethrow;
    }
  }

  void _start() {
    _server.listen(_handleHttp, onError: (_) => unawaited(close()));
    _socket.listen(_onDatagram, onError: (_) {});
    unawaited(_announce());
    _announcer = Timer.periodic(_announcementInterval, (_) => unawaited(_announce()));
  }

  Future<void> _announce() async {
    if (_closed || _announcementInFlight) return;
    _announcementInFlight = true;
    try {
      if (_canAnnounce != null && !await _canAnnounce()) return;
      List<AppPackageOffer> appOffers;
      try {
        appOffers = await _appUpdates?.availablePackages() ?? const <AppPackageOffer>[];
      } on Object {
        appOffers = const <AppPackageOffer>[];
      }
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'kind': 'mgread-paired-sync',
          'protocolVersion': pairedSyncProtocolVersion,
          'transport': 'http',
          'deviceId': identity.deviceId,
          'label': identity.label,
          'port': port,
          'ttlSeconds': _advertisedPeerLifetime.inSeconds,
          'appOffers': <Object?>[for (final offer in appOffers) offer.toJson()],
          if (_peerService != null) 'services': _peerService.advertisement,
        }),
      );
      _socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    } on Object {
      // A later announcement retries.
    } finally {
      _announcementInFlight = false;
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
        if (raw is! Map) continue;
        if (raw['kind'] == 'mgread-paired-sync-wake') {
          unawaited(_handleWakeRequest(raw, packet.address));
          continue;
        }
        if (raw['kind'] == 'mgread-paired-sync-wake-failure') {
          unawaited(_handleWakeFailure(raw, packet.address));
          continue;
        }
        final deviceId = raw['deviceId'];
        final label = raw['label'];
        final advertisedPort = raw['port'];
        final ttl = raw['ttlSeconds'];
        final rawAppOffers = raw['appOffers'] ?? const <Object?>[];
        if (raw['kind'] != 'mgread-paired-sync' ||
            raw['protocolVersion'] != pairedSyncProtocolVersion ||
            raw['transport'] != 'http' ||
            deviceId is! String ||
            deviceId == identity.deviceId ||
            !isValidPairedDeviceId(deviceId) ||
            label is! String ||
            _validDeviceLabel(label) == null ||
            advertisedPort is! int ||
            advertisedPort < 1 ||
            advertisedPort > 65535 ||
            ttl is! int ||
            ttl < 6 ||
            ttl > 120 ||
            rawAppOffers is! List ||
            rawAppOffers.length > 3) {
          continue;
        }
        final appOffers = <AppPackageOffer>[
          for (final value in rawAppOffers)
            AppPackageOffer.fromJson((value as Map).map<String, Object?>((key, value) => MapEntry(key as String, value))),
        ];
        _endpoints.add(
          PairedSyncEndpoint(
            address: packet.address.address,
            deviceId: deviceId,
            expiresAtUtc: DateTime.now().toUtc().add(Duration(seconds: ttl)),
            label: label,
            port: advertisedPort,
            appOffers: List<AppPackageOffer>.unmodifiable(appOffers),
          ),
        );
        final services = raw['services'];
        if (services is Map && services.length <= 8) {
          _peerService?.discovered(
            deviceId: deviceId,
            label: label,
            address: packet.address.address,
            port: advertisedPort,
            lifetime: Duration(seconds: ttl),
            services: Map<String, Object?>.from(services),
          );
        }
      } on Object {
        // Discovery data is untrusted.
      }
    }
  }

  Future<void> _handleHttp(HttpRequest request) async {
    try {
      if (!_eligiblePeer(request.connectionInfo?.remoteAddress)) {
        return await _respond(request.response, HttpStatus.forbidden, <String, Object?>{'error': 'not_private'});
      }
      if (_peerService != null && await _peerService.handleRequest(request)) return;
      final deviceId = request.headers.value(LanSyncHttpAuthentication.deviceHeader);
      final peer = deviceId == null ? null : await _devices.read(deviceId);
      final secret = deviceId == null ? null : await _identityStore.readPeerSecret(deviceId);
      if (peer == null ||
          secret == null ||
          !LanSyncHttpAuthentication.verify(request, sharedSecret: secret, acceptedNonces: _requestNonces)) {
        return await _respond(request.response, HttpStatus.unauthorized, <String, Object?>{'error': 'unauthorized'});
      }
      if (request.method == 'GET' && request.uri.path == '/v4/identity') {
        return await _respond(request.response, HttpStatus.ok, <String, Object?>{
          'protocolVersion': pairedSyncProtocolVersion,
          'deviceId': identity.deviceId,
          'label': identity.label,
        });
      }
      final segments = request.uri.pathSegments;
      if (await _handleAppPackageRequest(request, peer, segments)) return;
      if (request.method == 'POST' && request.uri.path == '/v4/sessions') {
        if (_closed) {
          return await _respond(request.response, HttpStatus.serviceUnavailable, <String, Object?>{'error': 'host_stopping'});
        }
        if (_sessions.length >= 4) {
          return await _respond(request.response, HttpStatus.serviceUnavailable, <String, Object?>{'error': 'busy'});
        }
        final body = await _readAuthenticatedJson(request);
        final remoteLabel = _validDeviceLabel(body['deviceLabel']);
        final exchange = _HttpExchange(
          id: _randomToken(18),
          peer: remoteLabel == null ? peer : peer.copyWith(label: remoteLabel),
          remoteManifestRaw: body['manifest'],
          remotePolicy: _WirePolicy.fromJson(body),
          requestId: body['requestId'] as String?,
        );
        _sessions[exchange.id] = exchange;
        unawaited(
          Future<void>.delayed(_sessionLifetime).then((_) async {
            if (_sessions[exchange.id] == exchange) {
              exchange.expire();
              await _retireExchange(exchange);
            }
          }),
        );
        unawaited(
          _onIncoming(
            PairedSyncServerSession._(exchange),
          ).catchError((Object error, StackTrace stack) => exchange.fail(error, stack)).whenComplete(() => _retireExchange(exchange)),
        );
        final value = await exchange.negotiation.future;
        return await _respond(request.response, HttpStatus.ok, value);
      }
      if (segments.length < 3 || segments[0] != 'v4' || segments[1] != 'sessions') {
        return await _respond(request.response, HttpStatus.notFound, <String, Object?>{'error': 'not_found'});
      }
      final exchange = _sessions[segments[2]];
      if (exchange == null || exchange.peer.deviceId != peer.deviceId) {
        return await _respond(request.response, HttpStatus.notFound, <String, Object?>{'error': 'session_missing'});
      }
      if (request.method == 'PUT' && segments.length == 5 && segments[3] == 'artifacts') {
        await exchange.acceptUpload(segments[4], request);
        return await _respond(request.response, HttpStatus.noContent, null);
      }
      if (request.method == 'PUT' && segments.length == 5 && segments[3] == 'local-documents') {
        await exchange.acceptLocalDocumentUpload(segments[4], request);
        return await _respond(request.response, HttpStatus.noContent, null);
      }
      if (request.method == 'PUT' && segments.length == 6 && segments[3] == 'local-documents' && segments[5] == 'cover') {
        await exchange.acceptLocalDocumentCoverUpload(segments[4], request);
        return await _respond(request.response, HttpStatus.noContent, null);
      }
      if (request.method == 'POST' && segments.length == 4 && segments[3] == 'prepare-uploads') {
        final body = await _readAuthenticatedJson(request);
        exchange.acceptUploadDescriptors(body['plugins']);
        exchange.uploadPrepared.completeIfPending();
        await exchange.uploadReady.future;
        return await _respond(request.response, HttpStatus.noContent, null);
      }
      if (request.method == 'POST' && segments.length == 6 && segments[3] == 'artifacts' && segments[5] == 'prepare') {
        final artifact = await exchange.artifact(segments[4]);
        return await _respond(request.response, HttpStatus.ok, <String, Object?>{'plugin': artifact.descriptor.toJson()});
      }
      if (request.method == 'POST' && segments.length == 4 && segments[3] == 'commit') {
        exchange.uploadsDone.completeIfPending();
        return await _respond(request.response, HttpStatus.ok, (await exchange.serverApplied.future).toJson());
      }
      if (request.method == 'GET' && segments.length == 5 && segments[3] == 'artifacts') {
        final artifact = await exchange.artifact(segments[4]);
        return await artifact.serve(request);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') && segments.length == 5 && segments[3] == 'local-documents') {
        final artifact = await exchange.localDocumentArtifact(segments[4]);
        return await artifact.serve(request);
      }
      if ((request.method == 'GET' || request.method == 'HEAD') &&
          segments.length == 6 &&
          segments[3] == 'local-documents' &&
          segments[5] == 'cover') {
        final artifact = await exchange.localDocumentCoverArtifact(segments[4]);
        return await artifact.serve(request);
      }
      if (request.method == 'POST' && segments.length == 4 && segments[3] == 'finish') {
        final body = await _readAuthenticatedJson(request);
        exchange.clientApplied.completeIfPending(_AppliedSummary.fromJson(body));
        await _respond(request.response, HttpStatus.noContent, null);
        await _retireExchange(exchange);
        return;
      }
      if (request.method == 'POST' && segments.length == 4 && segments[3] == 'fail') {
        final body = await _readAuthenticatedJson(request);
        exchange.fail(
          PairedSyncPeerFailureException(
            code: body['code'] as String,
            stage: body['stage'] as String,
            errorText: body['errorText'] as String,
          ),
          StackTrace.current,
        );
        await _respond(request.response, HttpStatus.noContent, null);
        await _retireExchange(exchange);
        return;
      }
      return await _respond(request.response, HttpStatus.notFound, <String, Object?>{'error': 'not_found'});
    } on Object catch (error, stack) {
      try {
        final id = request.uri.pathSegments.length > 2 ? request.uri.pathSegments[2] : null;
        final exchange = id == null ? null : _sessions[id];
        final failure = error is PairedSyncPeerFailureException
            ? error
            : PairedSyncPeerFailureException(
                code: _sessionFailureCode(exchange?.stage ?? 'request', error),
                stage: exchange?.stage ?? 'request',
                errorText: _boundedError(error),
              );
        await _respond(request.response, _httpStatus(error), <String, Object?>{
          'error': _errorCode(error),
          'detail': _boundedError(error),
          'code': failure.code,
          'stage': failure.stage,
          'errorText': failure.errorText,
        });
      } on Object {
        // The peer may have closed while the failure response was written.
      }
      final id = request.uri.pathSegments.length > 2 ? request.uri.pathSegments[2] : null;
      if (id != null) _sessions[id]?.fail(error, stack);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _peerService?.hostChanged(null);
    _announcer?.cancel();
    _socket.close();
    await _endpoints.close();
    final appPackages = _appPackages.entries.toList(growable: false);
    _appPackages.clear();
    for (final entry in appPackages) {
      await entry.value.package.close();
    }
    if (_sessions.isEmpty) {
      await _server.close(force: true);
    }
  }

  Future<void> _retireExchange(_HttpExchange exchange) async {
    if (!identical(_sessions[exchange.id], exchange)) return;
    _sessions.remove(exchange.id);
    await exchange.close();
    if (_closed && _sessions.isEmpty) {
      unawaited(_server.close(force: false));
    }
  }

  Future<void> _retireAppPackage(String token, _HostedAppPackage hosted) async {
    if (!identical(_appPackages[token], hosted)) return;
    _appPackages.remove(token);
    await hosted.package.close();
  }
}

final class PairedSyncClientSession {
  PairedSyncClientSession._(this.peer, this._endpoint, this._identity, this._secret);
  final PairedDevice peer;
  final PairedSyncEndpoint _endpoint;
  final LocalDeviceIdentity _identity;
  final List<int> _secret;
  final HttpClient _client = createLanSyncHttpClient();
  Uri get _base => Uri.parse('http://${_endpoint.address}:${_endpoint.port}');

  static Future<PairedSyncClientSession> connectAny({
    required Iterable<PairedSyncEndpoint> endpoints,
    required LocalDeviceIdentity identity,
    required PairedDevice peer,
    required List<int> sharedSecret,
  }) async {
    Object? last;
    for (final endpoint in endpoints.where((item) => item.deviceId == peer.deviceId)) {
      try {
        final client = createLanSyncHttpClient();
        final value = await _jsonRequest(
          client,
          Uri.parse('http://${endpoint.address}:${endpoint.port}/v4/identity'),
          'GET',
          null,
          identity.deviceId,
          sharedSecret,
        );
        client.close(force: true);
        final label = _validDeviceLabel(value['label']);
        if (value['protocolVersion'] != pairedSyncProtocolVersion || value['deviceId'] != peer.deviceId || label == null) {
          throw const LanSyncTransportException('lan_sync_protocol_incompatible');
        }
        return PairedSyncClientSession._(peer.copyWith(label: label), endpoint, identity, sharedSecret);
      } on Object catch (error) {
        last = error;
      }
    }
    throw last ?? const LanSyncTransportException('lan_sync_peer_offline');
  }

  Future<PairedSyncRunSummary> run({
    required LanSyncGateway gateway,
    PairedSyncOperation operation = PairedSyncOperation.bidirectional,
    String? requestId,
    PairedSyncStageObserver? onStage,
  }) async {
    var committed = false;
    String? activeSessionId;
    String stage = 'request';
    void enter(String value) {
      stage = value;
      onStage?.call(value);
    }

    try {
      final policy = _WirePolicy.fromDevice(peer, operation);
      enter('local_manifest');
      final localManifest = await _createManifest(gateway, policy);
      enter('manifest_exchange');
      final negotiation = await _jsonRequest(
        _client,
        _base.resolve('/v4/sessions'),
        'POST',
        <String, Object?>{
          'requestId': requestId,
          'deviceLabel': _identity.label,
          ...policy.toJson(),
          'manifest': localManifest.toPairedTasksJson(),
        },
        _identity.deviceId,
        _secret,
      );
      final sessionId = negotiation['sessionId'];
      if (sessionId is! String || !_validNonce(sessionId)) throw const LanSyncTransportException('lan_sync_handshake_invalid');
      activeSessionId = sessionId;
      final remoteManifest = _manifest(negotiation['manifest']);
      _WirePolicy.fromJson(negotiation);
      final sendSelection = _Selection.fromJson(negotiation['selection'], localManifest);
      enter('import_plan');
      final receivePlan = await _planImport(gateway, remoteManifest, includeLocalDocuments: policy.canReceive && policy.syncBookshelf);
      enter('send_payload');
      await _upload(gateway, localManifest, sendSelection, sessionId);
      final remoteApplied = _AppliedSummary.fromJson(
        await _jsonRequest(
          _client,
          _base.resolve('/v4/sessions/$sessionId/commit'),
          'POST',
          const <String, Object?>{},
          _identity.deviceId,
          _secret,
        ),
      );
      enter('receive_payload');
      final received = await _downloadAndApply(
        gateway,
        remoteManifest,
        receivePlan,
        sessionId,
        onLocalDocumentCommitted: () => committed = true,
      );
      committed = committed || received.books > 0 || received.plugins > 0;
      enter('complete');
      await _jsonRequest(
        _client,
        _base.resolve('/v4/sessions/$sessionId/finish'),
        'POST',
        received.toJson(),
        _identity.deviceId,
        _secret,
        allowEmpty: true,
      );
      return PairedSyncRunSummary(
        receivedBooks: received.books,
        receivedPlugins: received.plugins,
        sentBooks: remoteApplied.books,
        sentPlugins: remoteApplied.plugins,
        developmentConflicts: receivePlan.developmentConflicts + remoteApplied.developmentConflicts,
        skippedShelfItems: localManifest.skippedShelfItems + remoteManifest.skippedShelfItems,
      );
    } on Object catch (error, stack) {
      if (activeSessionId != null) {
        try {
          await _jsonRequest(
            _client,
            _base.resolve('/v4/sessions/$activeSessionId/fail'),
            'POST',
            <String, Object?>{'code': _sessionFailureCode(stage, error), 'stage': stage, 'errorText': _boundedError(error)},
            _identity.deviceId,
            _secret,
            allowEmpty: true,
          );
        } on Object {
          // Keep the originating failure when the peer is already gone.
        }
      }
      if (committed) throw PairedSyncPartialException(error, stage: stage, causeStackTrace: stack);
      rethrow;
    } finally {
      await close();
    }
  }

  Future<void> _upload(LanSyncGateway gateway, LanSyncManifest manifest, _Selection selection, String sessionId) async {
    final offers = manifest.plugins.where((item) => selection.pluginIds.contains(item.id)).toList(growable: false);
    final localOffers = manifest.localDocuments
        .where((item) => selection.localDocumentIds.contains(item.documentId))
        .toList(growable: false);
    final prepared = List<LanSyncHttpArtifact?>.filled(offers.length, null);
    final preparedLocal = List<LanSyncLocalDocumentHttpArtifact?>.filled(localOffers.length, null);
    final preparedCovers = List<LanSyncLocalDocumentHttpArtifact?>.filled(localOffers.length, null);
    try {
      await _runBoundedPluginTasks(offers.length, (index) async {
        final offer = offers[index];
        final item = await _materialize(gateway, offer, peer.platform.name);
        if (!_sameLogical(item.descriptor, offer)) {
          throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
        }
        prepared[index] = await LanSyncHttpArtifact.materialize(item.descriptor, item.bytes);
      });
      final artifacts = prepared.cast<LanSyncHttpArtifact>();
      if (artifacts.isNotEmpty) {
        await _jsonRequest(
          _client,
          _base.resolve('/v4/sessions/$sessionId/prepare-uploads'),
          'POST',
          <String, Object?>{'plugins': artifacts.map((item) => item.descriptor.toJson()).toList()},
          _identity.deviceId,
          _secret,
          allowEmpty: true,
        );
        await _runBoundedPluginTasks(artifacts.length, (index) => _uploadArtifact(artifacts[index], sessionId));
      }
      if (localOffers.isNotEmpty) {
        final localGateway = gateway;
        if (localGateway is! LanSyncLocalDocumentGateway) throw const LanSyncTransportException('lan_sync_local_documents_unsupported');
        await _runBoundedPluginTasks(localOffers.length, (index) async {
          final source = await (localGateway as LanSyncLocalDocumentGateway).openLocalDocumentOriginal(localOffers[index]);
          preparedLocal[index] = await LanSyncLocalDocumentHttpArtifact.materialize(localOffers[index], source);
          if (localOffers[index].coverSha256 != null) {
            final cover = await (localGateway as LanSyncLocalDocumentGateway).openLocalDocumentCover(localOffers[index]);
            if (cover == null) throw const LanSyncTransportException('lan_sync_local_cover_unavailable');
            preparedCovers[index] = await LanSyncLocalDocumentHttpArtifact.materialize(localOffers[index], cover, cover: true);
          }
        });
        await _runBoundedPluginTasks(localOffers.length, (index) {
          final cover = preparedCovers[index];
          return cover == null ? Future<void>.value() : _uploadLocalPayload(cover, sessionId, cover: true);
        });
        await _runBoundedPluginTasks(localOffers.length, (index) => _uploadLocalDocument(preparedLocal[index]!, sessionId));
      }
    } finally {
      for (final artifact in prepared) {
        await artifact?.close();
      }
      for (final artifact in preparedLocal) {
        await artifact?.close();
      }
      for (final artifact in preparedCovers) {
        await artifact?.close();
      }
    }
  }

  Future<void> _uploadLocalDocument(LanSyncLocalDocumentHttpArtifact artifact, String sessionId) =>
      _uploadLocalPayload(artifact, sessionId);

  Future<void> _uploadLocalPayload(LanSyncLocalDocumentHttpArtifact artifact, String sessionId, {bool cover = false}) async {
    final document = artifact.descriptor;
    final uri = _base.resolve(
      '/v4/sessions/$sessionId/local-documents/${Uri.encodeComponent(document.documentId)}${cover ? '/cover' : ''}',
    );
    final bytes = artifact.bytes;
    final checksum = artifact.sha256;
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final request = await _client.putUrl(uri);
        LanSyncHttpAuthentication.sign(
          request,
          deviceId: _identity.deviceId,
          sharedSecret: _secret,
          contentChecksum: LanSyncHttpAuthentication.bodyHash(const <int>[]),
        );
        request.headers
          ..set('x-mgread-content-sha256', checksum)
          ..contentType = ContentType.binary;
        request.contentLength = bytes;
        await request.addStream(artifact.openRead());
        final response = await request.close();
        final responseBytes = await response.fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
        if (response.statusCode == HttpStatus.noContent) return;
        if (response.statusCode < HttpStatus.internalServerError) throw _httpFailure(response.statusCode, responseBytes);
        lastError = _httpFailure(response.statusCode, responseBytes);
        lastStackTrace = StackTrace.current;
      } on PairedSyncPeerFailureException {
        rethrow;
      } on LanSyncTransportException {
        rethrow;
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<void> _uploadArtifact(LanSyncHttpArtifact artifact, String sessionId) async {
    final plugin = artifact.descriptor;
    final uri = _base.resolve('/v4/sessions/$sessionId/artifacts/${Uri.encodeComponent(plugin.id)}');
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final request = await _client.putUrl(uri);
        LanSyncHttpAuthentication.sign(request, deviceId: _identity.deviceId, sharedSecret: _secret, contentChecksum: plugin.checksum);
        request.contentLength = plugin.bytes;
        request.headers.contentType = ContentType.binary;
        await request.addStream(artifact.openRead());
        final response = await request.close();
        final responseBytes = await response.fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
        if (response.statusCode == HttpStatus.noContent) return;
        if (response.statusCode < HttpStatus.internalServerError) {
          throw _httpFailure(response.statusCode, responseBytes);
        }
        lastError = _httpFailure(response.statusCode, responseBytes);
        lastStackTrace = StackTrace.current;
      } on PairedSyncPeerFailureException {
        rethrow;
      } on LanSyncTransportException {
        rethrow;
      } on Object catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  Future<_AppliedSummary> _downloadAndApply(
    LanSyncGateway gateway,
    LanSyncManifest manifest,
    _ImportPlan plan,
    String sessionId, {
    void Function()? onLocalDocumentCommitted,
  }) async {
    final offered = manifest.plugins.where((item) => plan.selection.pluginIds.contains(item.id)).toList(growable: false);
    final plugins = List<LanSyncPluginDescriptor?>.filled(offered.length, null);
    await _runBoundedPluginTasks(offered.length, (index) async {
      final offer = offered[index];
      final prepared = await _jsonRequest(
        _client,
        _base.resolve('/v4/sessions/$sessionId/artifacts/${Uri.encodeComponent(offer.id)}/prepare'),
        'POST',
        const <String, Object?>{},
        _identity.deviceId,
        _secret,
      );
      final raw = prepared['plugin'];
      if (raw is! Map) throw const LanSyncTransportException('lan_sync_plugin_descriptor_invalid');
      final plugin = LanSyncPluginDescriptor.fromJson(raw.map<String, Object?>((key, value) => MapEntry(key as String, value)));
      if (!_sameLogical(plugin, offer)) throw const LanSyncTransportException('lan_sync_plugin_version_changed');
      plugins[index] = plugin;
    });
    final preparedPlugins = plugins.cast<LanSyncPluginDescriptor>();
    final localDocuments = manifest.localDocuments
        .where((item) => plan.selection.localDocumentIds.contains(item.documentId))
        .toList(growable: false);
    final receivedLocalDocumentIds = <String>{};
    final receivedLocalCoverIds = <String>{};
    if (preparedPlugins.isNotEmpty) {
      await gateway.preparePluginImports(preparedPlugins, forceUpgradePluginIds: plan.selection.pluginIds);
    }
    try {
      await _runBoundedPluginTasks(preparedPlugins.length, (index) async {
        final plugin = preparedPlugins[index];
        final uri = _base.resolve('/v4/sessions/$sessionId/artifacts/${Uri.encodeComponent(plugin.id)}');
        final stream = await const LanSyncHttpArtifactClient().download(
          uri,
          plugin,
          client: _client,
          authenticate: (request, hash) =>
              LanSyncHttpAuthentication.sign(request, deviceId: _identity.deviceId, sharedSecret: _secret, contentChecksum: hash),
        );
        await gateway.importPluginArchive(plugin, stream);
      });
      if (localDocuments.isNotEmpty) {
        final localGateway = gateway;
        if (localGateway is! LanSyncLocalDocumentGateway) throw const LanSyncTransportException('lan_sync_local_documents_unsupported');
        await _runBoundedPluginTasks(localDocuments.length, (index) async {
          final document = localDocuments[index];
          Stream<List<int>>? coverStream;
          if (document.coverSha256 != null) {
            final coverUri = _base.resolve('/v4/sessions/$sessionId/local-documents/${Uri.encodeComponent(document.documentId)}/cover');
            coverStream = await const LanSyncLocalDocumentHttpClient().download(
              coverUri,
              document,
              client: _client,
              cover: true,
              authenticate: (request, hash) =>
                  LanSyncHttpAuthentication.sign(request, deviceId: _identity.deviceId, sharedSecret: _secret, contentChecksum: hash),
            );
            receivedLocalCoverIds.add(document.documentId);
          }
          try {
            final uri = _base.resolve('/v4/sessions/$sessionId/local-documents/${Uri.encodeComponent(document.documentId)}');
            final stream = await const LanSyncLocalDocumentHttpClient().download(
              uri,
              document,
              client: _client,
              authenticate: (request, hash) =>
                  LanSyncHttpAuthentication.sign(request, deviceId: _identity.deviceId, sharedSecret: _secret, contentChecksum: hash),
            );
            await (localGateway as LanSyncLocalDocumentGateway).importLocalDocument(
              document,
              stream,
              useSenderMetadata: false,
              coverBytes: coverStream,
              coverMimeType: document.coverMimeType,
            );
          } finally {
            await discardLocalDocumentStream(coverStream);
          }
          receivedLocalDocumentIds.add(document.documentId);
          onLocalDocumentCommitted?.call();
        });
      }
      return await _finishApply(
        gateway,
        manifest,
        plan,
        receivedLocalDocumentIds: receivedLocalDocumentIds,
        receivedLocalCoverIds: receivedLocalCoverIds,
      );
    } on Object {
      try {
        await gateway.cancelPluginImports();
      } on Object {
        // Preserve the transfer/import failure that triggered cleanup.
      }
      rethrow;
    }
  }

  Future<void> close() async => _client.close(force: true);
}

final class PairedSyncServerSession {
  PairedSyncServerSession._(this._exchange);
  final _HttpExchange _exchange;
  PairedDevice get peer => _exchange.peer;
  String? get requestId => _exchange.requestId;
  Future<void> rejectBusy() async => _exchange.rejectBusy();
  Future<PairedSyncRunSummary> run({required LanSyncGateway gateway, PairedSyncStageObserver? onStage}) async {
    try {
      final remotePolicy = _exchange.remotePolicy;
      final localPolicy = _WirePolicy(
        canReceive: peer.canReceive && remotePolicy.canSend,
        canSend: peer.canSend && remotePolicy.canReceive,
        syncBookshelf: peer.syncBookshelf,
        syncPlugins: peer.syncPlugins,
      );
      _exchange.stage = 'local_manifest';
      onStage?.call(_exchange.stage);
      final localManifest = await _createManifest(gateway, localPolicy);
      _exchange.stage = 'manifest_exchange';
      onStage?.call(_exchange.stage);
      final remoteManifest = _exchange.remoteManifest;
      _exchange.stage = 'import_plan';
      onStage?.call(_exchange.stage);
      final plan = await _planImport(gateway, remoteManifest, includeLocalDocuments: localPolicy.canReceive && localPolicy.syncBookshelf);
      _exchange.configure(gateway, localManifest, plan);
      _exchange.negotiation.complete(<String, Object?>{
        'sessionId': _exchange.id,
        ...localPolicy.toJson(),
        'manifest': localManifest.toPairedTasksJson(),
        'selection': plan.selection.toJson(),
      });
      if (plan.selection.pluginIds.isNotEmpty) {
        await _exchange.uploadPrepared.future;
        await gateway.preparePluginImports(_exchange.uploadDescriptors.values.toList(), forceUpgradePluginIds: plan.selection.pluginIds);
        _exchange.uploadReady.completeIfPending();
      }
      _exchange.stage = 'receive_payload';
      onStage?.call(_exchange.stage);
      await _exchange.uploadsDone.future;
      final received = await _finishApply(
        gateway,
        remoteManifest,
        plan,
        receivedIds: _exchange.receivedIds,
        receivedLocalDocumentIds: _exchange.receivedLocalDocumentIds,
        receivedLocalCoverIds: _exchange.receivedLocalCoverIds,
      );
      _exchange.serverApplied.completeIfPending(received);
      _exchange.stage = 'send_payload';
      onStage?.call(_exchange.stage);
      final remoteApplied = await _exchange.clientApplied.future;
      onStage?.call('complete');
      return PairedSyncRunSummary(
        receivedBooks: received.books,
        receivedPlugins: received.plugins,
        sentBooks: remoteApplied.books,
        sentPlugins: remoteApplied.plugins,
        developmentConflicts: plan.developmentConflicts + remoteApplied.developmentConflicts,
        skippedShelfItems: localManifest.skippedShelfItems + remoteManifest.skippedShelfItems,
      );
    } on Object catch (error, stack) {
      _exchange.fail(error, stack);
      rethrow;
    }
  }

  Future<void> close() => _exchange.close();
}
