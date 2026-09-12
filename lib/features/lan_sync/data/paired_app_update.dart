/// 已配对在线设备的 App 包端点和主动拉取流程。
///
/// App 升级独立于自动数据同步与设备方向策略，只能由用户显式发起。
part of 'paired_sync_transport.dart';

final class _HostedAppPackage {
  const _HostedAppPackage(this.deviceId, this.package);
  final String deviceId;
  final PreparedAppPackage package;
}

extension _PairedAppUpdateHost on PairedSyncHost {
  Future<bool> _handleAppPackageRequest(HttpRequest request, PairedDevice peer, List<String> segments) async {
    if (request.method == 'POST' &&
        segments.length == 4 &&
        segments[0] == 'v4' &&
        segments[1] == 'app-packages' &&
        segments[3] == 'prepare') {
      await _readAuthenticatedJson(request);
      final platform = AppUpdatePlatform.parse(segments[2]);
      final service = _appUpdates;
      if (service == null || platform == AppUpdatePlatform.unknown) {
        throw const LanSyncTransportException('app_update_package_unavailable');
      }
      if (_appPackages.length >= 2) throw const LanSyncTransportException('lan_sync_peer_busy');
      final prepared = await service.preparePackage(platform);
      final token = _randomToken(18);
      final hosted = _HostedAppPackage(peer.deviceId, prepared);
      _appPackages[token] = hosted;
      unawaited(Future<void>.delayed(_sessionLifetime).then((_) => _retireAppPackage(token, hosted)));
      await _respond(request.response, HttpStatus.ok, <String, Object?>{'token': token, 'package': prepared.descriptor.toJson()});
      return true;
    }
    if (segments.length < 3 || segments[0] != 'v4' || segments[1] != 'app-packages') return false;
    final token = segments[2];
    final hosted = _appPackages[token];
    if (hosted == null || hosted.deviceId != peer.deviceId) {
      await _respond(request.response, HttpStatus.notFound, <String, Object?>{'error': 'app_package_missing'});
      return true;
    }
    if (request.method == 'GET' && segments.length == 3) {
      await serveAppPackage(request, hosted.package.file, hosted.package.descriptor);
      return true;
    }
    if (request.method == 'POST' && segments.length == 4 && segments[3] == 'complete') {
      await _readAuthenticatedJson(request);
      await _respond(request.response, HttpStatus.noContent, null);
      await _retireAppPackage(token, hosted);
      return true;
    }
    return false;
  }
}

/// Pulls one compatible App package from an online paired peer. This operation
/// is intentionally separate from bookshelf/plugin sync policy and never runs
/// as part of automatic data synchronization.
Future<void> pullPairedAppUpdate({
  required PairedSyncEndpoint endpoint,
  required LocalDeviceIdentity identity,
  required PairedDevice peer,
  required List<int> sharedSecret,
  required AppUpdateService service,
  required bool force,
  void Function(int bytes, int total)? onProgress,
}) async {
  final local = await service.currentVersion();
  final offer = endpoint.appOffers.where((item) => item.available && item.version.platform == local.platform).firstOrNull;
  if (offer == null) throw const LanSyncTransportException('app_update_platform_mismatch');
  if (!force && !isRemoteAppUpgrade(offer.version, local)) {
    throw const LanSyncTransportException('app_update_not_newer');
  }
  final client = createLanSyncHttpClient();
  final base = Uri.parse('http://${endpoint.address}:${endpoint.port}');
  File? file;
  try {
    final prepared = await _jsonRequest(
      client,
      base.resolve('/v4/app-packages/${offer.version.platform.name}/prepare'),
      'POST',
      const <String, Object?>{},
      identity.deviceId,
      sharedSecret,
    );
    final token = prepared['token'];
    final rawPackage = prepared['package'];
    if (token is! String || !_validNonce(token) || rawPackage is! Map) {
      throw const LanSyncTransportException('app_update_package_invalid');
    }
    final descriptor = AppPackageDescriptor.fromJson(rawPackage.map<String, Object?>((key, value) => MapEntry(key as String, value)));
    if (descriptor.version.platform != offer.version.platform ||
        descriptor.version.version != offer.version.version ||
        descriptor.version.buildNumber != offer.version.buildNumber) {
      throw const LanSyncTransportException('app_update_package_changed');
    }
    file = await downloadAppPackage(
      base.resolve('/v4/app-packages/$token'),
      descriptor,
      client: client,
      authenticate: (request, hash) =>
          LanSyncHttpAuthentication.sign(request, deviceId: identity.deviceId, sharedSecret: sharedSecret, contentChecksum: hash),
      onProgress: onProgress,
    );
    await _jsonRequest(
      client,
      base.resolve('/v4/app-packages/$token/complete'),
      'POST',
      const <String, Object?>{},
      identity.deviceId,
      sharedSecret,
      allowEmpty: true,
    );
    await service.launchInstaller(file, descriptor);
  } on Object {
    if (file != null && await file.exists()) await file.delete();
    rethrow;
  } finally {
    client.close(force: true);
  }
}
