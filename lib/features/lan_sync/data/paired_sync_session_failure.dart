/// 已认证同步会话中的远端失败信令。
///
/// 任一端在对端等待控制帧时失败，先通过加密会话回报稳定阶段、错误码和有界原因，
/// 再关闭连接；完整异常与堆栈仍只留在原始失败设备的调试诊断中。
part of 'paired_sync_transport.dart';

final class PairedSyncPeerFailureException implements Exception {
  const PairedSyncPeerFailureException({required this.code, required this.stage, required this.errorText});

  final String code;
  final String stage;
  final String errorText;

  @override
  String toString() => 'PairedSyncPeerFailureException(code: $code, stage: $stage, error: $errorText)';
}

Future<Map<String, Object?>> _readPairedSessionControl(
  PairedSecureConnection connection, {
  required Duration timeout,
  int maxBytes = lanSyncMaxControlFrameBytes,
}) async {
  final frame = await connection.readControl(maxBytes: maxBytes).timeout(timeout);
  _throwIfPairedSessionFailure(frame);
  return frame;
}

void _throwIfPairedSessionFailureFrame(LanSyncFrame frame) {
  if (frame case LanSyncControlFrame(:final value)) {
    _throwIfPairedSessionFailure(value);
  }
}

void _throwIfPairedSessionFailure(Map<String, Object?> frame) {
  if (frame['type'] != 'syncFailure') return;
  final code = frame['code'];
  final stage = frame['stage'];
  final errorText = frame['errorText'];
  if (code is! String ||
      !_validPairedFailureToken(code) ||
      stage is! String ||
      !_validPairedFailureToken(stage) ||
      errorText is! String ||
      errorText.isEmpty ||
      errorText.length > 512) {
    throw const LanSyncTransportException('lan_sync_failure_invalid');
  }
  throw PairedSyncPeerFailureException(code: code, stage: stage, errorText: errorText);
}

Future<void> _sendPairedSessionFailure(PairedSecureConnection connection, Object error, {required String stage}) async {
  var cause = error;
  if (error is PairedSyncPeerFailureException) return;
  if (error is PairedSyncPartialException) {
    cause = error.cause;
    stage = error.stage;
    if (cause is PairedSyncPeerFailureException) return;
  }
  final rawCode = _pairedSessionFailureCode(stage, cause);
  final code = _validPairedFailureToken(rawCode) ? rawCode : 'device_sync_${stage}_failed';
  final errorText = _boundedPairedFailureText(cause);
  try {
    await connection
        .sendControl(<String, Object?>{'type': 'syncFailure', 'code': code, 'stage': stage, 'errorText': errorText})
        .timeout(const Duration(seconds: 2));
  } on Object {
    // 对端可能已经断开；不得用失败回报异常覆盖原始同步错误。
  }
}

String _pairedSessionFailureCode(String stage, Object error) {
  if (error is LanSyncTransportException) return error.code;
  if (error is LanSyncGatewayException) return 'lan_sync_${stage}_${error.code}';
  if (error is TimeoutException) return 'lan_sync_${stage}_timeout';
  if (error is SocketException) return 'lan_sync_${stage}_socket_error';
  return 'device_sync_${stage}_failed';
}

String _boundedPairedFailureText(Object error) {
  final raw = error.toString();
  final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return error.runtimeType.toString();
  return normalized.length <= 512 ? normalized : normalized.substring(0, 512);
}

bool _validPairedFailureToken(String value) => value.length >= 3 && value.length <= 96 && RegExp(r'^[a-z0-9_]+$').hasMatch(value);
