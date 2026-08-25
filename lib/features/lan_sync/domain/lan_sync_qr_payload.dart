final class LanSyncQrPayload {
  const LanSyncQrPayload._();

  static const String _scheme = 'mgread';
  static const String _host = 'lan-sync';
  static const String _versionPath = '/v1';

  static String encode(String connectionAddress) {
    if (!_isConnectionAddress(connectionAddress)) {
      throw ArgumentError.value(
        connectionAddress,
        'connectionAddress',
        'Must be a bounded MgRead LAN sync connection address.',
      );
    }
    return Uri(
      scheme: _scheme,
      host: _host,
      path: _versionPath,
      queryParameters: <String, String>{'address': connectionAddress},
    ).toString();
  }

  static String? decode(String payload) {
    if (payload.length > 512) return null;
    final uri = Uri.tryParse(payload.trim());
    if (uri == null ||
        uri.scheme != _scheme ||
        uri.host != _host ||
        uri.path != _versionPath ||
        uri.fragment.isNotEmpty ||
        uri.queryParameters.length != 1) {
      return null;
    }
    final address = uri.queryParameters['address'];
    return address != null && _isConnectionAddress(address) ? address : null;
  }
}

bool _isConnectionAddress(String value) {
  final match = RegExp(
    r'^([A-Za-z0-9_-]{8,128})@([0-9.]+):([0-9]{1,5})$',
  ).firstMatch(value);
  final port = match == null ? null : int.tryParse(match.group(3)!);
  return match != null && port != null && port >= 1 && port <= 65535;
}
