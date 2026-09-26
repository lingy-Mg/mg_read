/// App 下载服务停滞时必须有界失败，不能把收到最后一字节当作校验或安装成功。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/app_transfer_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

void main() {
  for (final sendHeaders in [false, true]) {
    test('download times out when sender stalls ${sendHeaders ? 'mid-body' : 'before headers'}', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final bytes = [1, 2, 3];
      final checksum = lanSyncChecksum(bytes);
      server.listen((request) async {
        if (!sendHeaders) return;
        request.response.headers.set(HttpHeaders.etagHeader, '"crc32-$checksum"');
        request.response.contentLength = bytes.length;
        request.response.add([1]);
        await request.response.flush();
      });
      var verified = false;
      await expectLater(
        downloadAppPackage(
          Uri.parse('http://127.0.0.1:${server.port}/v1/package'),
          AppPackageDescriptor(
            version: const AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.0.0', buildNumber: 1),
            bytes: bytes.length,
            checksum: checksum,
            fileName: 'mg_read.apk',
          ),
          idleTimeout: const Duration(milliseconds: 150),
          onVerifying: () => verified = true,
        ),
        throwsA(predicate((error) => error.toString().contains('app_update_download_timeout'))),
      );
      expect(verified, isFalse);
    });
  }
}
