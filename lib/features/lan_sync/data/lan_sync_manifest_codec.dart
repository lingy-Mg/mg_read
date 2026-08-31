/// 扫码临时传输的 Manifest 解码与安全错误投影。
///
/// 只保留字段级稳定原因，不记录清单原始值；网络会话生命周期仍由主传输文件负责。
part of 'lan_sync_transport.dart';

LanSyncManifest _decodeLanSyncManifestFrame(Map<String, Object?> frame) {
  if (frame['type'] != 'manifest') {
    throw const LanSyncTransportException('lan_sync_manifest_invalid', reason: 'invalid_frame_type');
  }
  final raw = frame['value'];
  if (raw is! Map) {
    throw const LanSyncTransportException('lan_sync_manifest_invalid', reason: 'invalid_manifest_value');
  }
  try {
    return LanSyncManifest.fromJson(
      raw.map<String, Object?>((key, value) {
        if (key is! String) throw const FormatException('invalid_manifest_key');
        return MapEntry(key, value);
      }),
    );
  } on FormatException catch (error, stackTrace) {
    Error.throwWithStackTrace(LanSyncTransportException('lan_sync_manifest_invalid', reason: _safeManifestReason(error)), stackTrace);
  }
}

String _safeManifestReason(FormatException error) {
  final reason = error.message.toString();
  return RegExp(r'^[a-z0-9_]{3,96}$').hasMatch(reason) ? reason : 'invalid_manifest';
}
