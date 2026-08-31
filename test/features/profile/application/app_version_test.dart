/// Installed application version projection tests.
///
/// Verifies that profile presentation receives the platform version name and
/// does not substitute the separate platform build number.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:mg_read/features/profile/application/app_version.dart';

void main() {
  test('loads the installed package version name', () async {
    PackageInfo.setMockInitialValues(
      appName: 'MgRead',
      packageName: 'com.example.mg_read',
      version: '9.8.7',
      buildNumber: '321',
      buildSignature: '',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(await container.read(appVersionProvider.future), '9.8.7');
  });
}
