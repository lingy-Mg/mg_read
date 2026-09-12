/// 临时 App 传输与通用 App 制品 HTTP 下载。
///
/// 职责：
/// - 用独立二维码建立一次性 App 会话并显示双方版本。
/// - 通过标准 HTTP Range、ETag 和 CRC32 传输 App 包。
/// - 下载完成后才把本地文件交给平台安装边界。
///
/// 注意：App 包不会进入书架/插件 manifest；普通升级只接受更高版本，显式
/// force 才允许相同或更低版本。跨平台包由发送端可用目录和接收端平台共同决定。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_client.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';

const Duration appTransferSessionLifetime = Duration(minutes: 10);

sealed class AppTransferSenderEvent {
  const AppTransferSenderEvent();
}

final class AppTransferSenderPairing extends AppTransferSenderEvent {
  const AppTransferSenderPairing({required this.code, required this.remoteVersion, required this.offeredVersion});
  final String code;
  final AppVersionInfo remoteVersion;
  final AppVersionInfo offeredVersion;
}

final class AppTransferSenderProgress extends AppTransferSenderEvent {
  const AppTransferSenderProgress(this.bytes, this.total);
  final int bytes;
  final int total;
}

final class AppTransferSenderDone extends AppTransferSenderEvent {
  const AppTransferSenderDone();
}

final class AppTransferSenderFailed extends AppTransferSenderEvent {
  const AppTransferSenderFailed(this.code, this.error, this.stackTrace);
  final String code;
  final Object? error;
  final StackTrace? stackTrace;
}

final class AppTransferSenderService {
  AppTransferSenderService._({
    required this.sessionId,
    required this.localVersion,
    required this.offers,
    required this.connectionOffer,
    required this._service,
    required this._server,
  });

  final String sessionId;
  final AppVersionInfo localVersion;
  final List<AppPackageOffer> offers;
  final AppTransferConnectionOffer connectionOffer;
  final AppUpdateService _service;
  final HttpServer _server;
  final StreamController<AppTransferSenderEvent> _events = StreamController<AppTransferSenderEvent>.broadcast();
  Timer? _expiry;
  String? _pairingCode;
  AppUpdatePlatform? _selectedPlatform;
  PreparedAppPackage? _prepared;
  bool _closed = false;

  Stream<AppTransferSenderEvent> get events => _events.stream;

  static Future<AppTransferSenderService> start(AppUpdateService service) async {
    final local = await service.currentVersion();
    final offers = await service.availablePackages();
    if (!offers.any((item) => item.available)) throw StateError('app_update_package_unavailable');
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) throw const LanSyncTransportException('lan_sync_local_network_unavailable');
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    try {
      final sessionId = _randomToken(18);
      final result = AppTransferSenderService._(
        sessionId: sessionId,
        localVersion: local,
        offers: offers,
        connectionOffer: AppTransferConnectionOffer(sessionId: sessionId, port: server.port, addresses: addresses),
        service: service,
        server: server,
      );
      result._start();
      return result;
    } on Object {
      await server.close(force: true);
      rethrow;
    }
  }

  void _start() {
    _server.listen(_handle, onError: (Object error, StackTrace stack) => _fail('app_update_listen_failed', error, stack));
    _expiry = Timer(appTransferSessionLifetime, () => _fail('app_update_session_expired'));
  }

  Future<void> _handle(HttpRequest request) async {
    var authenticated = false;
    try {
      if (request.connectionInfo?.remoteAddress case final address? when !isLanSyncPrivateIpv4(address.address)) {
        return await _respond(request.response, HttpStatus.forbidden, <String, Object?>{'error': 'not_private'});
      }
      if (request.method == 'POST' && request.uri.path == '/v1/pair') {
        final body = await _readJson(request);
        final remote = AppVersionInfo.fromJson(body);
        final nonce = body['clientNonce'];
        if (body['sessionId'] != sessionId || nonce is! String || nonce.length < 20) {
          throw const LanSyncTransportException('app_update_handshake_invalid');
        }
        final offer = offers.where((item) => item.available && item.version.platform == remote.platform).firstOrNull;
        if (offer == null) throw const LanSyncTransportException('app_update_platform_mismatch');
        final serverNonce = _randomToken(16);
        final code = _pairing('$sessionId|$nonce|$serverNonce');
        _pairingCode = code;
        _selectedPlatform = remote.platform;
        _events.add(AppTransferSenderPairing(code: code, remoteVersion: remote, offeredVersion: offer.version));
        return await _respond(request.response, HttpStatus.ok, <String, Object?>{
          'serverNonce': serverNonce,
          'pairingCode': code,
          'offer': offer.toJson(),
        });
      }
      if (request.headers.value('x-mgread-session') != _pairingCode) {
        return await _respond(request.response, HttpStatus.unauthorized, <String, Object?>{'error': 'pairing_required'});
      }
      authenticated = true;
      if (request.method == 'POST' && request.uri.path == '/v1/package') {
        _prepared ??= await _service.preparePackage(_selectedPlatform!);
        return await _respond(request.response, HttpStatus.ok, <String, Object?>{'package': _prepared!.descriptor.toJson()});
      }
      if (request.method == 'GET' && request.uri.path == '/v1/package') {
        final prepared = _prepared;
        if (prepared == null) throw const LanSyncTransportException('app_update_package_not_prepared');
        await serveAppPackage(request, prepared.file, prepared.descriptor);
        _events.add(AppTransferSenderProgress(prepared.descriptor.bytes, prepared.descriptor.bytes));
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v1/complete') {
        _events.add(const AppTransferSenderDone());
        await _respond(request.response, HttpStatus.noContent, null);
        await close();
        return;
      }
      await _respond(request.response, HttpStatus.notFound, <String, Object?>{'error': 'not_found'});
    } on Object catch (error, stack) {
      if (authenticated) _fail(error is LanSyncTransportException ? error.code : 'app_update_transfer_failed', error, stack);
      try {
        await _respond(request.response, HttpStatus.badRequest, <String, Object?>{'error': _errorCode(error)});
      } on Object {
        // The receiver may disconnect while an error is being reported.
      }
    }
  }

  void _fail(String code, [Object? error, StackTrace? stack]) {
    if (_closed) return;
    _events.add(AppTransferSenderFailed(code, error, stack));
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry?.cancel();
    await _prepared?.close();
    await _server.close(force: true);
    await _events.close();
  }
}

final class AppTransferReceiverConnection {
  AppTransferReceiverConnection._(this.remoteOffer, this.pairingCode, this._base, this._client);

  final AppPackageOffer remoteOffer;
  final String pairingCode;
  final Uri _base;
  final HttpClient _client;

  static Future<AppTransferReceiverConnection> connectAny(AppTransferConnectionOffer offer, AppVersionInfo localVersion) async {
    Object? last;
    for (final address in offer.addresses) {
      final client = createLanSyncHttpClient();
      try {
        final base = Uri.parse('http://$address:${offer.port}');
        final nonce = _randomToken(16);
        final value = await _request(client, base.resolve('/v1/pair'), <String, Object?>{
          'sessionId': offer.sessionId,
          'clientNonce': nonce,
          ...localVersion.toJson(),
        }, null).timeout(const Duration(seconds: 5));
        final serverNonce = value['serverNonce'];
        final code = value['pairingCode'];
        if (serverNonce is! String || code != _pairing('${offer.sessionId}|$nonce|$serverNonce') || value['offer'] is! Map) {
          throw const LanSyncTransportException('app_update_pairing_invalid');
        }
        final remote = AppPackageOffer.fromJson(
          (value['offer'] as Map).map<String, Object?>((key, value) => MapEntry(key as String, value)),
        );
        return AppTransferReceiverConnection._(remote, code! as String, base, client);
      } on Object catch (error) {
        last = error;
        client.close(force: true);
      }
    }
    throw last ?? const LanSyncTransportException('app_update_connect_failed');
  }

  Future<void> downloadAndInstall(
    AppUpdateService service,
    AppVersionInfo localVersion, {
    required bool force,
    void Function(int, int)? onProgress,
  }) async {
    if (!force && !isRemoteAppUpgrade(remoteOffer.version, localVersion)) {
      throw const LanSyncTransportException('app_update_not_newer');
    }
    final prepared = await _request(_client, _base.resolve('/v1/package'), const <String, Object?>{}, pairingCode);
    if (prepared['package'] is! Map) throw const LanSyncTransportException('app_update_package_invalid');
    final descriptor = AppPackageDescriptor.fromJson(
      (prepared['package'] as Map).map<String, Object?>((key, value) => MapEntry(key as String, value)),
    );
    _verifyPreparedOffer(descriptor, remoteOffer);
    final file = await downloadAppPackage(
      _base.resolve('/v1/package'),
      descriptor,
      client: _client,
      authenticate: (request, _) => request.headers.set('x-mgread-session', pairingCode),
      onProgress: onProgress,
    );
    try {
      await _request(_client, _base.resolve('/v1/complete'), const <String, Object?>{}, pairingCode, allowEmpty: true);
      await service.launchInstaller(file, descriptor);
    } on Object {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  void close() => _client.close(force: true);
}

Future<void> serveAppPackage(HttpRequest request, File file, AppPackageDescriptor descriptor) async {
  if (request.method != 'GET' && request.method != 'HEAD') {
    request.response.statusCode = HttpStatus.methodNotAllowed;
    await request.response.close();
    return;
  }
  final etag = '"crc32-${descriptor.checksum}"';
  final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
  final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
  final range = rangeHeader == null || (ifRange != null && ifRange != etag) ? null : _range(rangeHeader, descriptor.bytes);
  final response = request.response;
  response.headers
    ..set(HttpHeaders.acceptRangesHeader, 'bytes')
    ..set(HttpHeaders.etagHeader, etag)
    ..contentType = ContentType.binary;
  if (rangeHeader != null && ifRange != null && ifRange != etag) {
    response.statusCode = HttpStatus.ok;
    response.contentLength = descriptor.bytes;
  } else if (rangeHeader != null && range == null) {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${descriptor.bytes}');
    response.contentLength = 0;
    return response.close();
  } else if (range != null) {
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.$1}-${range.$2}/${descriptor.bytes}');
    response.contentLength = range.$2 - range.$1 + 1;
  } else {
    response.statusCode = HttpStatus.ok;
    response.contentLength = descriptor.bytes;
  }
  if (request.method == 'GET') await response.addStream(file.openRead(range?.$1 ?? 0, (range?.$2 ?? descriptor.bytes - 1) + 1));
  await response.close();
}

Future<File> downloadAppPackage(
  Uri uri,
  AppPackageDescriptor descriptor, {
  HttpClient? client,
  void Function(HttpClientRequest request, String contentChecksum)? authenticate,
  void Function(int, int)? onProgress,
}) async {
  final ownedClient = client == null;
  final http = client ?? createLanSyncHttpClient();
  // Android's FileProvider only grants the Package Installer files below the
  // app cache directory. Directory.systemTemp is not guaranteed to resolve
  // there, so an otherwise verified APK could not be exposed for installation.
  final temporaryRoot = Platform.isAndroid ? await getTemporaryDirectory() : Directory.systemTemp;
  final directory = await temporaryRoot.createTemp('mgread-app-download-');
  final file = File('${directory.path}${Platform.pathSeparator}${descriptor.fileName}');
  var offset = 0;
  String? etag;
  try {
    for (var attempt = 0; attempt < 4 && offset < descriptor.bytes; attempt++) {
      try {
        final request = await http.getUrl(uri);
        authenticate?.call(request, lanSyncChecksum(const <int>[]));
        if (offset > 0) {
          request.headers
            ..set(HttpHeaders.rangeHeader, 'bytes=$offset-')
            ..set(HttpHeaders.ifRangeHeader, etag!);
        }
        final response = await request.close();
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          offset = 0;
          etag = null;
          await file.writeAsBytes(const <int>[]);
          continue;
        }
        if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
          throw LanSyncTransportException('app_update_http_failed', reason: 'status_${response.statusCode}');
        }
        final responseEtag = response.headers.value(HttpHeaders.etagHeader);
        if (responseEtag != '"crc32-${descriptor.checksum}"') throw const LanSyncTransportException('app_update_package_changed');
        if (offset > 0 && response.statusCode == HttpStatus.ok) {
          offset = 0;
          await file.writeAsBytes(const <int>[]);
        }
        etag = responseEtag;
        final sink = file.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
        try {
          await for (final chunk in response) {
            sink.add(chunk);
            offset += chunk.length;
            if (offset > descriptor.bytes) throw const LanSyncTransportException('app_update_size_mismatch');
            onProgress?.call(offset, descriptor.bytes);
          }
          await sink.close();
        } on Object {
          await sink.close().catchError((_) {});
          rethrow;
        }
      } on LanSyncTransportException {
        rethrow;
      } on Object {
        offset = await file.exists() ? await file.length() : 0;
        if (attempt == 3) rethrow;
      }
    }
    if (offset != descriptor.bytes) throw const LanSyncTransportException('app_update_transfer_incomplete');
    if (await _checksumFile(file) != descriptor.checksum) {
      throw const LanSyncTransportException('app_update_hash_mismatch');
    }
    return file;
  } on Object {
    if (await directory.exists()) await directory.delete(recursive: true);
    rethrow;
  } finally {
    if (ownedClient) http.close(force: true);
  }
}

Future<String> _checksumFile(File file) async {
  final sink = LanSyncChecksumSink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  return sink.close();
}

void _verifyPreparedOffer(AppPackageDescriptor descriptor, AppPackageOffer offer) {
  if (descriptor.version.platform != offer.version.platform ||
      descriptor.version.version != offer.version.version ||
      descriptor.version.buildNumber != offer.version.buildNumber) {
    throw const LanSyncTransportException('app_update_package_changed');
  }
}

(int, int)? _range(String value, int length) {
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
  if (length <= 0 || match == null || value.contains(',')) return null;
  final first = match.group(1)!;
  final second = match.group(2)!;
  if (first.isEmpty) {
    final suffix = int.tryParse(second);
    if (suffix == null || suffix <= 0) return null;
    return (length - suffix.clamp(1, length), length - 1);
  }
  final start = int.tryParse(first);
  final end = second.isEmpty ? length - 1 : int.tryParse(second);
  if (start == null || end == null || start >= length || end < start) return null;
  return (start, end.clamp(start, length - 1));
}

Future<Map<String, Object?>> _request(
  HttpClient client,
  Uri uri,
  Map<String, Object?> body,
  String? code, {
  bool allowEmpty = false,
}) async {
  final bytes = utf8.encode(jsonEncode(body));
  final request = await client.postUrl(uri);
  if (code != null) request.headers.set('x-mgread-session', code);
  request.headers.contentType = ContentType.json;
  request.contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close();
  final text = await utf8.decodeStream(response);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    Object? reason;
    try {
      reason = (jsonDecode(text) as Map)['error'];
    } on Object {
      reason = 'status_${response.statusCode}';
    }
    throw LanSyncTransportException(reason?.toString() ?? 'app_update_http_failed');
  }
  if (text.isEmpty && allowEmpty) return <String, Object?>{};
  final raw = jsonDecode(text);
  if (raw is! Map) throw const LanSyncTransportException('app_update_control_invalid');
  return raw.map<String, Object?>((key, value) => MapEntry(key as String, value));
}

Future<Map<String, Object?>> _readJson(HttpRequest request) async {
  final bytes = await request.fold<List<int>>(<int>[], (buffer, chunk) {
    if (buffer.length + chunk.length > 64 * 1024) throw const LanSyncTransportException('app_update_control_too_large');
    return buffer..addAll(chunk);
  });
  final raw = jsonDecode(utf8.decode(bytes));
  if (raw is! Map) throw const LanSyncTransportException('app_update_control_invalid');
  return raw.map<String, Object?>((key, value) => MapEntry(key as String, value));
}

Future<void> _respond(HttpResponse response, int status, Map<String, Object?>? value) async {
  response.statusCode = status;
  if (value != null) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(value));
  }
  await response.close();
}

String _randomToken(int length) => base64Url.encode(List<int>.generate(length, (_) => Random.secure().nextInt(256))).replaceAll('=', '');

String _pairing(String value) {
  final digest = sha256.convert(utf8.encode(value)).bytes;
  var number = 0;
  for (final byte in digest.take(4)) {
    number = (number << 8) | byte;
  }
  return (number % 1000000).toString().padLeft(6, '0');
}

String _errorCode(Object error) => error is LanSyncTransportException ? error.code : 'app_update_transfer_failed';
