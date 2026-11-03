import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_failure_environment.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('package metadata and preferences are frozen per report', () async {
    final info = Completer<PackageInfo>();
    var enabled = false;
    final environment = AppFailureEnvironment(
      packageInfoLoader: () => info.future,
      proxyPreferences: () => {'customSourceProxyEnabled': enabled.toString()},
    );
    final early = environment.snapshot();
    expect(early['versionMetadata'], 'loading');
    expect(early['appVersion'], 'unknown');
    info.complete(PackageInfo(appName: 'MgRead', packageName: 'com.mgread', version: '0.12.17', buildNumber: '482'));
    await Future<void>.value();
    enabled = true;
    final ready = environment.snapshot();
    expect(ready['appVersion'], '0.12.17');
    expect(ready['buildNumber'], '482');
    expect(ready['versionMetadata'], 'available');
    expect(ready['platform'], isNotEmpty);
    expect(ready['selectedNodeBackend'], isNotEmpty);
    expect(ready['vpnStatus'], 'not_observed');
    expect(ready['customSourceProxyEnabled'], 'true');
    expect(early['customSourceProxyEnabled'], 'false');
    expect(early['appVersion'], 'unknown');
    expect(() => ready['appVersion'] = 'changed', throwsUnsupportedError);
  });

  test('metadata and preference failures do not reopen the error path', () async {
    final environment = AppFailureEnvironment(
      packageInfoLoader: () async => throw StateError('metadata unavailable'),
      proxyPreferences: () => throw StateError('settings unavailable'),
    );
    await Future<void>.value();
    final snapshot = environment.snapshot();
    expect(snapshot['versionMetadata'], 'unavailable');
    expect(snapshot['customSourceProxyEnabled'], 'unavailable');
  });
}
