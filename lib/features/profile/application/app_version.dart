/// Application-owned access to the installed MgRead package version.
///
/// Responsibilities:
/// - Read the platform package version once per application ProviderScope.
/// - Expose a presentation-safe fallback when package metadata is unavailable.
///
/// Notes:
/// - The displayed version is the platform version name; the build number is
///   intentionally not presented as part of the user-facing version label.
///
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

const String unavailableAppVersion = '--';

/// Loads the version name embedded in the currently running application.
final appVersionProvider = FutureProvider<String>((Ref ref) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final version = packageInfo.version.trim();
  return version.isEmpty ? unavailableAppVersion : version;
});
