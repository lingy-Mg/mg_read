import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';

final class LanSyncConnectionOffer {
  LanSyncConnectionOffer({required this.sessionId, required this.port, required Iterable<String> addresses})
    : addresses = normalizeLanSyncAddresses(addresses) {
    if (!_isSessionId(sessionId)) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Invalid session ID.');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'Invalid TCP port.');
    }
    if (this.addresses.isEmpty) {
      throw ArgumentError.value(addresses, 'addresses', 'At least one private LAN IPv4 address is required.');
    }
  }

  final String sessionId;
  final int port;
  final List<String> addresses;
}

final class LanSyncQrPayload {
  const LanSyncQrPayload._();

  static const String _scheme = 'mgread';
  static const String _host = 'lan-sync';
  static const String _versionPath = '/v2';
  static const int _maxPayloadLength = 2048;

  static String encode(LanSyncConnectionOffer offer) => Uri(
    scheme: _scheme,
    host: _host,
    path: _versionPath,
    queryParameters: <String, String>{'session': offer.sessionId, 'port': offer.port.toString(), 'addresses': offer.addresses.join(',')},
  ).toString();

  static LanSyncConnectionOffer? decode(String payload) {
    if (payload.length > _maxPayloadLength) return null;
    final uri = Uri.tryParse(payload.trim());
    if (uri == null ||
        uri.scheme != _scheme ||
        uri.host != _host ||
        uri.path != _versionPath ||
        uri.fragment.isNotEmpty ||
        uri.queryParameters.length != 3) {
      return null;
    }
    final sessionId = uri.queryParameters['session'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final rawAddresses = uri.queryParameters['addresses'];
    if (sessionId == null || !_isSessionId(sessionId) || port == null || port < 1 || port > 65535 || rawAddresses == null) {
      return null;
    }
    final addresses = rawAddresses.split(',');
    if (addresses.isEmpty ||
        addresses.length > lanSyncMaxCandidateAddresses ||
        addresses.toSet().length != addresses.length ||
        addresses.any((address) => !isLanSyncPrivateIpv4(address))) {
      return null;
    }
    return LanSyncConnectionOffer(sessionId: sessionId, port: port, addresses: addresses);
  }
}

bool _isSessionId(String value) => value.length >= 8 && value.length <= 128 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
