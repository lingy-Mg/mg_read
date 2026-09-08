/// 局域网 App 版本发现、制品描述和升级判定模型。
///
/// 职责：
/// - 只暴露可展示的版本、目标平台和经校验的制品元数据。
/// - 统一普通升级与显式强制安装的版本判定。
///
/// 注意：
/// - Windows 与 Android 制品不可交叉安装；Windows Debug 可额外提供工程内的 release APK。
/// - 路径、配对密钥和下载地址都不进入跨设备模型。
library;

import 'package:flutter/foundation.dart';

const int appUpdateMaxPackageBytes = 1536 * 1024 * 1024;

enum AppUpdatePlatform {
  android,
  windows,
  macos,
  unknown;

  static AppUpdatePlatform parse(Object? value) => switch (value) {
    'android' => AppUpdatePlatform.android,
    'windows' => AppUpdatePlatform.windows,
    'macos' => AppUpdatePlatform.macos,
    _ => AppUpdatePlatform.unknown,
  };
}

@immutable
final class AppVersionInfo {
  const AppVersionInfo({required this.platform, required this.version, required this.buildNumber});

  final AppUpdatePlatform platform;
  final String version;
  final int buildNumber;

  String get displayVersion => buildNumber > 0 ? '$version ($buildNumber)' : version;

  Map<String, Object?> toJson() => <String, Object?>{'platform': platform.name, 'version': version, 'buildNumber': buildNumber};

  factory AppVersionInfo.fromJson(Map<String, Object?> json) {
    final platform = AppUpdatePlatform.parse(json['platform']);
    final version = json['version'];
    final buildNumber = json['buildNumber'];
    if (platform == AppUpdatePlatform.unknown ||
        version is! String ||
        version.trim().isEmpty ||
        version.length > 128 ||
        buildNumber is! int ||
        buildNumber < 0 ||
        buildNumber > 2147483647) {
      throw const FormatException('invalid_app_version');
    }
    return AppVersionInfo(platform: platform, version: version.trim(), buildNumber: buildNumber);
  }
}

@immutable
final class AppPackageOffer {
  const AppPackageOffer({required this.version, required this.available, this.reason});

  final AppVersionInfo version;
  final bool available;
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{...version.toJson(), 'available': available, if (reason != null) 'reason': reason};

  factory AppPackageOffer.fromJson(Map<String, Object?> json) {
    final available = json['available'];
    final reason = json['reason'];
    if (available is! bool || (reason != null && (reason is! String || reason.length > 128))) {
      throw const FormatException('invalid_app_offer');
    }
    return AppPackageOffer(version: AppVersionInfo.fromJson(json), available: available, reason: reason as String?);
  }
}

@immutable
final class AppPackageDescriptor {
  const AppPackageDescriptor({required this.version, required this.bytes, required this.sha256, required this.fileName});

  final AppVersionInfo version;
  final int bytes;
  final String sha256;
  final String fileName;

  Map<String, Object?> toJson() => <String, Object?>{...version.toJson(), 'bytes': bytes, 'sha256': sha256, 'fileName': fileName};

  factory AppPackageDescriptor.fromJson(Map<String, Object?> json) {
    final bytes = json['bytes'];
    final sha256 = json['sha256'];
    final fileName = json['fileName'];
    if (bytes is! int ||
        bytes <= 0 ||
        bytes > appUpdateMaxPackageBytes ||
        sha256 is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        fileName is! String ||
        fileName.isEmpty ||
        fileName.length > 128 ||
        fileName.contains('/') ||
        fileName.contains(r'\')) {
      throw const FormatException('invalid_app_package');
    }
    return AppPackageDescriptor(version: AppVersionInfo.fromJson(json), bytes: bytes, sha256: sha256, fileName: fileName);
  }
}

bool isRemoteAppUpgrade(AppVersionInfo remote, AppVersionInfo local) {
  if (remote.platform != local.platform) return false;
  final versionComparison = _compareVersion(remote.version, local.version);
  return versionComparison > 0 || (versionComparison == 0 && remote.buildNumber > local.buildNumber);
}

int _compareVersion(String left, String right) {
  final leftParts = left.split(RegExp(r'[.+-]'));
  final rightParts = right.split(RegExp(r'[.+-]'));
  final count = leftParts.length > rightParts.length ? leftParts.length : rightParts.length;
  for (var index = 0; index < count; index++) {
    final a = index < leftParts.length ? leftParts[index] : '0';
    final b = index < rightParts.length ? rightParts[index] : '0';
    final aNumber = int.tryParse(a);
    final bNumber = int.tryParse(b);
    final comparison = aNumber != null && bNumber != null ? aNumber.compareTo(bNumber) : a.compareTo(b);
    if (comparison != 0) return comparison;
  }
  return 0;
}
