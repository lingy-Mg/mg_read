/// Process-owned metadata sampled into error reports, without starting Runtime.
/// Package metadata loads once in the background; early failures retain an
/// explicit loading/unavailable state. Proxy preferences describe report time,
/// while the HTTP exception carries the route sampled for the failing request.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:package_info_plus/package_info_plus.dart';

final class AppFailureEnvironment {
  AppFailureEnvironment({Future<PackageInfo> Function()? packageInfoLoader, this.proxyPreferences}) {
    unawaited(_loadPackageInfo(packageInfoLoader ?? PackageInfo.fromPlatform));
  }

  final Map<String, String> Function()? proxyPreferences;
  String _version = 'unknown';
  String _build = 'unknown';
  String _versionState = 'loading';

  Future<void> _loadPackageInfo(Future<PackageInfo> Function() loader) async {
    try {
      final info = await loader();
      _version = info.version.isEmpty ? 'unknown' : info.version;
      _build = info.buildNumber.isEmpty ? 'unknown' : info.buildNumber;
      _versionState = 'available';
    } catch (_) {
      _versionState = 'unavailable';
    }
  }

  Map<String, String> snapshot() {
    final result = <String, String>{
      'appVersion': _version,
      'buildNumber': _build,
      'versionMetadata': _versionState,
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'selectedNodeBackend': const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')
          ? 'not_included'
          : Platform.isAndroid
          ? AndroidNodeRuntimeSettings.instance.active == AndroidNodeBackend.javet
                ? 'android-javet'
                : 'android-node-process'
          : 'desktop-node',
      'vpnStatus': 'not_observed',
      'proxyPreferenceSnapshot': 'report_time',
    };
    try {
      result.addAll(proxyPreferences?.call() ?? {'customSourceProxyEnabled': 'unknown'});
    } catch (_) {
      result['customSourceProxyEnabled'] = 'unavailable';
    }
    return Map<String, String>.unmodifiable(result);
  }
}
