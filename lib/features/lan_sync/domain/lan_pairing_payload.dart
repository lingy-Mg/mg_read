/// 首次设备配对二维码载荷。
///
/// 载荷只在展示端前台有效十分钟；其中的 256-bit 预共享密钥在配对提交后作为逐设备长期密钥保存。
library;

import 'dart:convert';

import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

final class LanPairingOffer {
  LanPairingOffer({
    required Iterable<String> addresses,
    required this.deviceId,
    required this.label,
    required this.port,
    required Iterable<int> secret,
    required this.sessionId,
  }) : addresses = normalizeLanSyncAddresses(addresses),
       secret = List<int>.unmodifiable(secret) {
    if (!isValidPairedDeviceId(deviceId) ||
        label.trim().isEmpty ||
        label.length > 128 ||
        port < 1 ||
        port > 65535 ||
        this.secret.length != 32 ||
        sessionId.length < 16 ||
        sessionId.length > 128 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)) {
      throw ArgumentError('Invalid LAN pairing offer.');
    }
  }

  final List<String> addresses;
  final String deviceId;
  final String label;
  final int port;
  final List<int> secret;
  final String sessionId;
}

final class LanPairingQrPayload {
  const LanPairingQrPayload._();

  static String encode(LanPairingOffer offer) => Uri(
    scheme: 'mgread',
    host: 'device-pair',
    path: '/v1',
    queryParameters: <String, String>{
      'addresses': offer.addresses.join(','),
      'device': offer.deviceId,
      'label': offer.label,
      'port': offer.port.toString(),
      'secret': base64Url.encode(offer.secret).replaceAll('=', ''),
      'session': offer.sessionId,
    },
  ).toString();

  static LanPairingOffer? decode(String value) {
    if (value.length > 4096) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'mgread' ||
        uri.host != 'device-pair' ||
        uri.path != '/v1' ||
        uri.fragment.isNotEmpty ||
        uri.queryParameters.length != 6) {
      return null;
    }
    try {
      final addresses = (uri.queryParameters['addresses'] ?? '').split(',');
      if (addresses.toSet().length != addresses.length) return null;
      final secret = base64Url.decode(base64Url.normalize(uri.queryParameters['secret'] ?? ''));
      final port = int.parse(uri.queryParameters['port'] ?? '');
      return LanPairingOffer(
        addresses: addresses,
        deviceId: uri.queryParameters['device'] ?? '',
        label: uri.queryParameters['label'] ?? '',
        port: port,
        secret: secret,
        sessionId: uri.queryParameters['session'] ?? '',
      );
    } on Object {
      return null;
    }
  }
}
