/// Android App-update bridge contract.
///
/// Android host code is not included in ordinary Flutter unit-test compilation,
/// so these focused source contracts guard the Dart MethodChannel names and the
/// manifest/FileProvider security boundary used by the system Package Installer.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final activity = File(
    '$root${Platform.pathSeparator}android${Platform.pathSeparator}app${Platform.pathSeparator}src${Platform.pathSeparator}main${Platform.pathSeparator}kotlin${Platform.pathSeparator}com${Platform.pathSeparator}mgread${Platform.pathSeparator}mg_read${Platform.pathSeparator}MainActivity.kt',
  );
  final manifest = File(
    '$root${Platform.pathSeparator}android${Platform.pathSeparator}app${Platform.pathSeparator}src${Platform.pathSeparator}main${Platform.pathSeparator}AndroidManifest.xml',
  );
  final paths = File(
    '$root${Platform.pathSeparator}android${Platform.pathSeparator}app${Platform.pathSeparator}src${Platform.pathSeparator}main${Platform.pathSeparator}res${Platform.pathSeparator}xml${Platform.pathSeparator}app_update_file_paths.xml',
  );

  test('Android bridge exposes App-package and install-permission operations', () async {
    final source = await activity.readAsString();

    expect(source, contains('APP_UPDATE_CHANNEL = "mgread/app_update"'));
    expect(source, contains('"getInstalledApkPath" -> installedApkPath(result)'));
    expect(source, contains('"ensureInstallPermission" -> ensureInstallPermission(result)'));
    expect(source, contains('"installApk" -> installApk(call.argument<String>("path"), result)'));
    expect(source, contains('applicationInfo.sourceDir'));
  });

  test('received APK is delegated to the confirmed system installer', () async {
    final source = await activity.readAsString();

    expect(source, contains('FileProvider.getUriForFile'));
    expect(source, contains('Intent.ACTION_VIEW'));
    expect(source, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
    expect(source, contains('packageManager.canRequestPackageInstalls()'));
    expect(source, contains('Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES'));
    expect(source, isNot(contains('PackageInstaller.Session')));
  });

  test('manifest grants only a non-exported FileProvider URI', () async {
    final source = await manifest.readAsString();
    final filePaths = await paths.readAsString();

    expect(source, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
    expect(source, contains('androidx.core.content.FileProvider'));
    expect(source, contains(r'android:authorities="${applicationId}.app_update_provider"'));
    expect(source, contains('android:exported="false"'));
    expect(source, contains('android:grantUriPermissions="true"'));
    expect(filePaths, contains('<cache-path'));
    expect(filePaths, contains('path="."'));
  });
}
