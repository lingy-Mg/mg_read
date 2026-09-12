/// 临时 App 传输二维码的独立载荷。
///
/// App 包与书架数据使用不同二维码类型，避免接收端把安装请求送进数据导入会话。
library;

import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';

final class AppTransferConnectionOffer {
  AppTransferConnectionOffer({required this.sessionId, required this.port, required Iterable<String> addresses})
    : addresses = normalizeLanSyncAddresses(addresses) {
    if (!_validSessionId(sessionId) || port < 1 || port > 65535 || this.addresses.isEmpty) {
      throw ArgumentError('Invalid App transfer connection offer.');
    }
  }

  final String sessionId;
  final int port;
  final List<String> addresses;
}

final class AppTransferQrPayload {
  const AppTransferQrPayload._();

  static const int _maxPayloadLength = 2048;

  static String encode(AppTransferConnectionOffer offer) => Uri(
    scheme: 'mgread',
    host: 'app-transfer',
    path: '/v1',
    queryParameters: <String, String>{'session': offer.sessionId, 'port': offer.port.toString(), 'addresses': offer.addresses.join(',')},
  ).toString();

  static AppTransferConnectionOffer? decode(String payload) {
    if (payload.length > _maxPayloadLength) return null;
    final uri = Uri.tryParse(payload.trim());
    if (uri == null ||
        uri.scheme != 'mgread' ||
        uri.host != 'app-transfer' ||
        uri.path != '/v1' ||
        uri.fragment.isNotEmpty ||
        uri.queryParameters.length != 3) {
      return null;
    }
    final sessionId = uri.queryParameters['session'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final rawAddresses = uri.queryParameters['addresses'];
    if (sessionId == null || !_validSessionId(sessionId) || port == null || port < 1 || port > 65535 || rawAddresses == null) {
      return null;
    }
    final addresses = rawAddresses.split(',');
    if (addresses.isEmpty ||
        addresses.length > 8 ||
        addresses.toSet().length != addresses.length ||
        addresses.any((value) => !isLanSyncPrivateIpv4(value))) {
      return null;
    }
    return AppTransferConnectionOffer(sessionId: sessionId, port: port, addresses: addresses);
  }
}

bool _validSessionId(String value) => value.length >= 8 && value.length <= 128 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
