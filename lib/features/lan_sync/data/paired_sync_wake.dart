/// 已配对设备的签名 UDP 控制协议。
///
/// 只负责请求对端发起认证 HTTP 会话，或回报稳定失败阶段和有界技术原因；信任关系、
/// 重放窗口和 Socket 生命周期由 [PairedSyncHost] 持有。
part of 'paired_sync_transport.dart';

final class PairedSyncWakeRequest {
  const PairedSyncWakeRequest({required this.endpoint, required this.operation, required this.requestId});

  final PairedSyncEndpoint endpoint;
  final PairedSyncOperation operation;
  final String requestId;
}

final class PairedSyncWakeFailure {
  const PairedSyncWakeFailure({
    required this.deviceId,
    required this.code,
    required this.stage,
    required this.requestId,
    required this.errorText,
  });

  final String deviceId;
  final String code;
  final String stage;
  final String requestId;
  final String errorText;
}

final class PairedSyncRemoteFailureException implements Exception {
  const PairedSyncRemoteFailureException({required this.code, required this.stage, required this.errorText});

  final String code;
  final String stage;
  final String errorText;

  @override
  String toString() => 'PairedSyncRemoteFailureException(code: $code, stage: $stage, error: $errorText)';
}

extension _PairedSyncWakeHandling on PairedSyncHost {
  Future<void> _handleWakeRequest(Map<dynamic, dynamic> raw, InternetAddress sourceAddress) async {
    final callback = _onWakeRequest;
    if (callback == null || _closed || !isLanSyncPrivateIpv4(sourceAddress.address)) return;
    try {
      final deviceId = raw['deviceId'];
      final targetDeviceId = raw['targetDeviceId'];
      final label = _validDeviceLabel(raw['label']);
      final port = raw['port'];
      final requestId = raw['requestId'];
      final operation = _wakeOperation(raw['operation']);
      final encodedMac = raw['mac'];
      if (raw['protocolVersion'] != pairedSyncProtocolVersion ||
          deviceId is! String ||
          !isValidPairedDeviceId(deviceId) ||
          targetDeviceId != identity.deviceId ||
          label == null ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          requestId is! String ||
          !_validNonce(requestId) ||
          operation == null ||
          encodedMac is! String) {
        return;
      }
      final peer = await _devices.read(deviceId);
      final secret = await _identityStore.readPeerSecret(deviceId);
      if (peer == null || secret == null) return;
      final expected = await _wakeMac(
        secret,
        requestId: requestId,
        deviceId: deviceId,
        targetDeviceId: identity.deviceId,
        operation: operation,
        port: port,
      );
      if (!_constantTimeEquals(expected, _decodeMac(encodedMac))) return;
      final now = DateTime.now().toUtc();
      _acceptedWakeRequests.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
      if (_acceptedWakeRequests.containsKey(requestId)) return;
      if (_acceptedWakeRequests.length >= 64) _acceptedWakeRequests.remove(_acceptedWakeRequests.keys.first);
      _acceptedWakeRequests[requestId] = now.add(const Duration(minutes: 1));
      await callback(
        PairedSyncWakeRequest(
          endpoint: PairedSyncEndpoint(
            address: sourceAddress.address,
            deviceId: deviceId,
            expiresAtUtc: now.add(pairedSyncPeerLifetime),
            label: label,
            port: port,
          ),
          operation: operation,
          requestId: requestId,
        ),
      );
    } on Object {
      // 未认证、重放或格式错误的唤醒包直接忽略。
    }
  }

  Future<void> _handleWakeFailure(Map<dynamic, dynamic> raw, InternetAddress sourceAddress) async {
    final callback = _onWakeFailure;
    if (callback == null || _closed || !isLanSyncPrivateIpv4(sourceAddress.address)) return;
    try {
      final deviceId = raw['deviceId'];
      final targetDeviceId = raw['targetDeviceId'];
      final requestId = raw['requestId'];
      final code = raw['code'];
      final stage = raw['stage'];
      final errorText = _validWakeErrorText(raw['errorText']);
      final encodedMac = raw['mac'];
      if (raw['protocolVersion'] != pairedSyncProtocolVersion ||
          deviceId is! String ||
          !isValidPairedDeviceId(deviceId) ||
          targetDeviceId != identity.deviceId ||
          requestId is! String ||
          !_validNonce(requestId) ||
          code is! String ||
          !_validFailureToken(code) ||
          stage is! String ||
          !_validFailureToken(stage) ||
          errorText == null ||
          encodedMac is! String) {
        return;
      }
      final peer = await _devices.read(deviceId);
      final secret = await _identityStore.readPeerSecret(deviceId);
      if (peer == null || secret == null) return;
      final expected = await _wakeFailureMac(
        secret,
        requestId: requestId,
        deviceId: deviceId,
        targetDeviceId: identity.deviceId,
        code: code,
        stage: stage,
        errorText: errorText,
      );
      if (!_constantTimeEquals(expected, _decodeMac(encodedMac))) return;
      await callback(PairedSyncWakeFailure(deviceId: deviceId, code: code, stage: stage, requestId: requestId, errorText: errorText));
    } on Object {
      // 未认证或格式错误的远端失败回报直接忽略。
    }
  }
}

String createPairedSyncWakeRequestId() => _randomToken(18);

Future<void> sendPairedSyncWakeRequest({
  required LocalDeviceIdentity identity,
  required PairedSyncEndpoint endpoint,
  required List<int> sharedSecret,
  required PairedSyncOperation operation,
  required int localPort,
  required String requestId,
  int discoveryPort = pairedSyncDiscoveryPort,
}) async {
  if (sharedSecret.length != 32 ||
      !_validNonce(requestId) ||
      !isLanSyncPrivateIpv4(endpoint.address) ||
      localPort < 1 ||
      localPort > 65535 ||
      discoveryPort < 1 ||
      discoveryPort > 65535) {
    throw const LanSyncTransportException('lan_sync_wake_invalid');
  }
  final mac = await _wakeMac(
    sharedSecret,
    requestId: requestId,
    deviceId: identity.deviceId,
    targetDeviceId: endpoint.deviceId,
    operation: operation,
    port: localPort,
  );
  final bytes = utf8.encode(
    jsonEncode(<String, Object?>{
      'kind': 'mgread-paired-sync-wake',
      'protocolVersion': pairedSyncProtocolVersion,
      'deviceId': identity.deviceId,
      'targetDeviceId': endpoint.deviceId,
      'label': identity.label,
      'port': localPort,
      'requestId': requestId,
      'operation': operation.name,
      'mac': base64Url.encode(mac).replaceAll('=', ''),
    }),
  );
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      socket.send(bytes, InternetAddress(endpoint.address), discoveryPort);
      if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  } finally {
    socket.close();
  }
}

Future<void> sendPairedSyncWakeFailure({
  required LocalDeviceIdentity identity,
  required PairedSyncEndpoint endpoint,
  required List<int> sharedSecret,
  required String requestId,
  required String code,
  required String stage,
  required String errorText,
  int discoveryPort = pairedSyncDiscoveryPort,
}) async {
  final boundedErrorText = _validWakeErrorText(errorText);
  if (sharedSecret.length != 32 ||
      !_validNonce(requestId) ||
      !isLanSyncPrivateIpv4(endpoint.address) ||
      !_validFailureToken(code) ||
      !_validFailureToken(stage) ||
      boundedErrorText == null ||
      discoveryPort < 1 ||
      discoveryPort > 65535) {
    throw const LanSyncTransportException('lan_sync_wake_failure_invalid');
  }
  final mac = await _wakeFailureMac(
    sharedSecret,
    requestId: requestId,
    deviceId: identity.deviceId,
    targetDeviceId: endpoint.deviceId,
    code: code,
    stage: stage,
    errorText: boundedErrorText,
  );
  final bytes = utf8.encode(
    jsonEncode(<String, Object?>{
      'kind': 'mgread-paired-sync-wake-failure',
      'protocolVersion': pairedSyncProtocolVersion,
      'deviceId': identity.deviceId,
      'targetDeviceId': endpoint.deviceId,
      'requestId': requestId,
      'code': code,
      'stage': stage,
      'errorText': boundedErrorText,
      'mac': base64Url.encode(mac).replaceAll('=', ''),
    }),
  );
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    for (var attempt = 0; attempt < 3; attempt++) {
      socket.send(bytes, InternetAddress(endpoint.address), discoveryPort);
      if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  } finally {
    socket.close();
  }
}

PairedSyncOperation? _wakeOperation(Object? value) {
  for (final operation in PairedSyncOperation.values) {
    if (operation.name == value) return operation;
  }
  return null;
}

Future<List<int>> _wakeMac(
  List<int> secret, {
  required String requestId,
  required String deviceId,
  required String targetDeviceId,
  required PairedSyncOperation operation,
  required int port,
}) async {
  final transcript = '$pairedSyncProtocolVersion|$requestId|$deviceId|$targetDeviceId|${operation.name}|$port';
  final mac = await Hmac.sha256().calculateMac(utf8.encode(transcript), secretKey: SecretKey(secret));
  return mac.bytes;
}

Future<List<int>> _wakeFailureMac(
  List<int> secret, {
  required String requestId,
  required String deviceId,
  required String targetDeviceId,
  required String code,
  required String stage,
  required String errorText,
}) async {
  final transcript = '$pairedSyncProtocolVersion|wake-failure|$requestId|$deviceId|$targetDeviceId|$code|$stage|$errorText';
  final mac = await Hmac.sha256().calculateMac(utf8.encode(transcript), secretKey: SecretKey(secret));
  return mac.bytes;
}

List<int> _decodeMac(String encoded) {
  try {
    return base64Url.decode(base64Url.normalize(encoded));
  } on FormatException {
    return const <int>[];
  }
}

bool _constantTimeEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _validFailureToken(String value) => value.length >= 3 && value.length <= 96 && RegExp(r'^[a-z0-9_]+$').hasMatch(value);

String? _validWakeErrorText(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return null;
  return normalized.length <= 256 ? normalized : normalized.substring(0, 256);
}
