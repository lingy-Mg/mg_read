/// Windows/Android App 制品来源与安装入口。
///
/// Windows 仅归档当前 [mg_read.exe] 所在发布 bundle 的普通文件，并写入受限
/// 静态文件清单。进程退出后，外部更新器只按该清单覆盖或清理由前一清单管理的
/// 文件；用户数据和未声明文件永远不删除。Android 交给系统 Package Installer
/// 验签和确认。Windows Debug 可从工程相对路径探测 release APK 及其真实元数据。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

const MethodChannel _appUpdateChannel = MethodChannel('mgread/app_update');
const String _windowsBundleManifestName = '.mgread-bundle.json';
const int _windowsBundleMaxFiles = 4096;

typedef WindowsUpdaterStarter = Future<void> Function(String executable, List<String> arguments);
typedef AppUpdateTemporaryDirectory = Future<Directory> Function(String prefix);

/// Platform effects are injectable so tests never start PowerShell or exit Dart.
final class PlatformAppUpdateDependencies {
  PlatformAppUpdateDependencies({
    required this.isAndroid,
    required this.isWindows,
    required this.isMacOS,
    required this.isDebug,
    required this.resolvedExecutable,
    required this.currentDirectory,
    required this.processId,
    required this.startWindowsUpdater,
    required this.exitAfterWindowsUpdater,
    required this.createTemporaryDirectory,
  });

  factory PlatformAppUpdateDependencies.platform() => PlatformAppUpdateDependencies(
    isAndroid: Platform.isAndroid,
    isWindows: Platform.isWindows,
    isMacOS: Platform.isMacOS,
    isDebug: kDebugMode,
    resolvedExecutable: Platform.resolvedExecutable,
    currentDirectory: Directory.current,
    processId: pid,
    startWindowsUpdater: (executable, arguments) async {
      await Process.start(executable, arguments, mode: ProcessStartMode.detached);
    },
    exitAfterWindowsUpdater: () async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    },
    createTemporaryDirectory: Directory.systemTemp.createTemp,
  );

  final bool isAndroid;
  final bool isWindows;
  final bool isMacOS;
  final bool isDebug;
  final String resolvedExecutable;
  final Directory currentDirectory;
  final int processId;
  final WindowsUpdaterStarter startWindowsUpdater;
  final Future<void> Function() exitAfterWindowsUpdater;
  final AppUpdateTemporaryDirectory createTemporaryDirectory;
}

final class PlatformAppUpdateService implements AppUpdateService {
  PlatformAppUpdateService({PlatformAppUpdateDependencies? dependencies})
    : _dependencies = dependencies ?? PlatformAppUpdateDependencies.platform();

  final PlatformAppUpdateDependencies _dependencies;
  Future<AppVersionInfo>? _currentFuture;
  Future<List<AppPackageOffer>>? _offersFuture;

  @override
  Future<AppVersionInfo> currentVersion() => _currentFuture ??= _readCurrentVersion();

  @override
  Future<List<AppPackageOffer>> availablePackages() => _offersFuture ??= _readAvailablePackages();

  @override
  Future<PreparedAppPackage> preparePackage(AppUpdatePlatform platform) async {
    final offers = await availablePackages();
    final offer = offers.where((item) => item.version.platform == platform && item.available).firstOrNull;
    if (offer == null) throw StateError('app_update_package_unavailable');
    return switch (platform) {
      AppUpdatePlatform.android => _prepareAndroidPackage(offer.version),
      AppUpdatePlatform.windows => _prepareWindowsPackage(offer.version),
      AppUpdatePlatform.macos || AppUpdatePlatform.unknown => throw UnsupportedError('app_update_platform_unsupported'),
    };
  }

  @override
  Future<void> ensureInstallPermission() async {
    if (!_dependencies.isAndroid) return;
    try {
      await _appUpdateChannel.invokeMethod<void>('ensureInstallPermission');
    } on PlatformException catch (error) {
      throw StateError(error.code);
    }
  }

  @override
  Future<void> launchInstaller(File package, AppPackageDescriptor descriptor) async {
    if (descriptor.version.platform == AppUpdatePlatform.android && _dependencies.isAndroid) {
      try {
        await _appUpdateChannel.invokeMethod<void>('installApk', <String, Object?>{'path': package.path});
        return;
      } on PlatformException catch (error) {
        throw StateError('${error.code}:${error.message ?? 'AndroidException'}');
      }
    }
    if (descriptor.version.platform == AppUpdatePlatform.windows && _dependencies.isWindows) {
      await _verifyWindowsPackage(package, descriptor);
      await _launchWindowsUpdater(package, descriptor);
      return;
    }
    throw StateError('app_update_platform_mismatch');
  }

  Future<AppVersionInfo> _readCurrentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return AppVersionInfo(
      platform: _currentPlatform,
      version: info.version.trim().isEmpty ? '0.0.0' : info.version.trim(),
      buildNumber: int.tryParse(info.buildNumber.trim()) ?? 0,
    );
  }

  AppUpdatePlatform get _currentPlatform => _dependencies.isAndroid
      ? AppUpdatePlatform.android
      : _dependencies.isWindows
      ? AppUpdatePlatform.windows
      : _dependencies.isMacOS
      ? AppUpdatePlatform.macos
      : AppUpdatePlatform.unknown;

  Future<List<AppPackageOffer>> _readAvailablePackages() async {
    final current = await currentVersion();
    final offers = <AppPackageOffer>[
      AppPackageOffer(
        version: current,
        available: current.platform == AppUpdatePlatform.android || current.platform == AppUpdatePlatform.windows,
        reason: current.platform == AppUpdatePlatform.macos ? 'app_update_platform_unsupported' : null,
      ),
    ];
    if (_dependencies.isWindows && _dependencies.isDebug) {
      final apk = await locateDebugReleaseApk(_candidateProjectRoots());
      if (apk != null) offers.add(AppPackageOffer(version: apk.version, available: true));
    }
    return List<AppPackageOffer>.unmodifiable(offers);
  }

  Future<PreparedAppPackage> _prepareAndroidPackage(AppVersionInfo version) async {
    File? source;
    if (_dependencies.isAndroid) {
      final path = await _appUpdateChannel.invokeMethod<String>('getInstalledApkPath');
      if (path != null && path.isNotEmpty) source = File(path);
    } else if (_dependencies.isWindows && _dependencies.isDebug) {
      source = (await locateDebugReleaseApk(_candidateProjectRoots()))?.file;
    }
    if (source == null || !await source.exists()) throw StateError('app_update_package_unavailable');
    return _existingPackage(source, version, 'mg_read-${version.version}-android.apk');
  }

  Future<PreparedAppPackage> _prepareWindowsPackage(AppVersionInfo version) async {
    if (!_dependencies.isWindows) throw StateError('app_update_platform_mismatch');
    final executable = File(_dependencies.resolvedExecutable).absolute;
    if (!isSafeWindowsUpdateTarget(executable) || !await executable.exists()) {
      throw StateError('app_update_windows_target_invalid');
    }
    final files = await collectWindowsBundleFiles(executable.parent);
    final temporary = await _dependencies.createTemporaryDirectory('mgread-app-package-');
    final archive = File('${temporary.path}${Platform.pathSeparator}mg_read-${version.version}-windows.zip');
    try {
      await createWindowsBundleArchive(archive: archive, version: version, files: files);
      final prepared = await _existingPackage(archive, version, archive.uri.pathSegments.last);
      return PreparedAppPackage(
        descriptor: prepared.descriptor,
        file: prepared.file,
        onClose: () async {
          await prepared.close();
          if (await temporary.exists()) await temporary.delete(recursive: true);
        },
      );
    } on Object {
      if (await temporary.exists()) await temporary.delete(recursive: true);
      rethrow;
    }
  }

  Future<PreparedAppPackage> _existingPackage(File file, AppVersionInfo version, String fileName) async {
    final bytes = await file.length();
    if (bytes <= 0 || bytes > appUpdateMaxPackageBytes) throw StateError('app_update_package_size_invalid');
    final digest = await _checksumFile(file);
    return PreparedAppPackage(
      descriptor: AppPackageDescriptor(version: version, bytes: bytes, checksum: digest, fileName: fileName),
      file: file,
    );
  }

  Future<String> _checksumFile(File file) async {
    final sink = LanSyncChecksumSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    return sink.close();
  }

  Iterable<Directory> _candidateProjectRoots() sync* {
    final seen = <String>{};
    var current = _dependencies.currentDirectory.absolute;
    for (var depth = 0; depth < 8; depth++) {
      if (seen.add(current.path) && File('${current.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) yield current;
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    current = File(_dependencies.resolvedExecutable).absolute.parent;
    for (var depth = 0; depth < 8; depth++) {
      if (seen.add(current.path) && File('${current.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) yield current;
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
  }

  Future<void> _verifyWindowsPackage(File package, AppPackageDescriptor descriptor) async {
    if (!descriptor.fileName.toLowerCase().endsWith('.zip') || !package.uri.pathSegments.last.toLowerCase().endsWith('.zip')) {
      throw StateError('app_update_windows_package_invalid');
    }
    if (!await package.exists() || await package.length() != descriptor.bytes) {
      throw StateError('app_update_package_size_invalid');
    }
    if (await _checksumFile(package) != descriptor.checksum) {
      throw StateError('app_update_hash_mismatch');
    }
  }

  Future<void> _launchWindowsUpdater(File package, AppPackageDescriptor descriptor) async {
    final executable = File(_dependencies.resolvedExecutable).absolute;
    if (!isSafeWindowsUpdateTarget(executable) || !await executable.exists()) {
      throw StateError('app_update_windows_target_invalid');
    }
    final work = await _dependencies.createTemporaryDirectory('mgread-app-updater-');
    final script = File('${work.path}${Platform.pathSeparator}update.ps1');
    await script.writeAsString(_windowsUpdaterScript, flush: true);
    await _dependencies.startWindowsUpdater(
      'powershell.exe',
      windowsUpdaterArguments(
        script: script,
        package: package,
        target: executable.parent,
        executable: executable,
        processId: _dependencies.processId,
        expectedChecksum: descriptor.checksum,
      ),
    );
    unawaited(_dependencies.exitAfterWindowsUpdater());
  }
}

/// A regular file from the static Windows runner bundle.
@immutable
final class WindowsBundleFile {
  const WindowsBundleFile({required this.file, required this.relativePath});

  final File file;
  final String relativePath;
}

/// The debug-only APK candidate and the version embedded by Gradle's output metadata.
@immutable
final class DebugReleaseApk {
  const DebugReleaseApk(this.file, this.version);

  final File file;
  final AppVersionInfo version;
}

/// Enumerates a bounded, link-free runner bundle without touching user data.
@visibleForTesting
Future<List<WindowsBundleFile>> collectWindowsBundleFiles(Directory bundle) async {
  final executable = File('${bundle.path}${Platform.pathSeparator}mg_read.exe');
  final assets = Directory('${bundle.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets');
  if (!await executable.exists() || !await assets.exists()) throw StateError('app_update_windows_bundle_invalid');

  final root = bundle.absolute.path;
  final prefix = root.endsWith(Platform.pathSeparator) ? root : '$root${Platform.pathSeparator}';
  final files = <WindowsBundleFile>[];
  var totalBytes = 0;
  await for (final entity in bundle.list(recursive: true, followLinks: false)) {
    if (entity is Link) throw StateError('app_update_windows_bundle_link_invalid');
    if (entity is! File) continue;
    final absolute = entity.absolute.path;
    if (!absolute.startsWith(prefix)) throw StateError('app_update_windows_bundle_path_invalid');
    final relativePath = absolute.substring(prefix.length).replaceAll('\\', '/');
    if (!_isSafeBundleFilePath(relativePath)) throw StateError('app_update_windows_bundle_path_invalid');
    final bytes = await entity.length();
    totalBytes += bytes;
    if (files.length >= _windowsBundleMaxFiles || totalBytes > appUpdateMaxPackageBytes) {
      throw StateError('app_update_windows_bundle_size_invalid');
    }
    files.add(WindowsBundleFile(file: entity, relativePath: relativePath));
  }
  files.sort((left, right) => left.relativePath.compareTo(right.relativePath));
  if (!files.any((file) => file.relativePath == 'mg_read.exe') ||
      !files.any((file) => file.relativePath.startsWith('data/flutter_assets/'))) {
    throw StateError('app_update_windows_bundle_invalid');
  }
  return List<WindowsBundleFile>.unmodifiable(files);
}

/// Writes the bounded static file inventory and the actual running App version into a ZIP.
@visibleForTesting
Future<void> createWindowsBundleArchive({
  required File archive,
  required AppVersionInfo version,
  required List<WindowsBundleFile> files,
}) async {
  if (version.platform != AppUpdatePlatform.windows || files.isEmpty || files.length > _windowsBundleMaxFiles) {
    throw StateError('app_update_windows_bundle_invalid');
  }
  var totalBytes = 0;
  final names = <String>{};
  for (final entry in files) {
    if (!_isSafeBundleFilePath(entry.relativePath) || !names.add(entry.relativePath)) {
      throw StateError('app_update_windows_bundle_path_invalid');
    }
    totalBytes += await entry.file.length();
    if (totalBytes > appUpdateMaxPackageBytes) throw StateError('app_update_windows_bundle_size_invalid');
  }
  if (!names.contains('mg_read.exe') || !names.any((name) => name.startsWith('data/flutter_assets/'))) {
    throw StateError('app_update_windows_bundle_invalid');
  }

  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    encoder.create(archive.path, level: DeflateLevel.bestSpeed);
    opened = true;
    for (final entry in files) {
      await encoder.addFile(entry.file, entry.relativePath, DeflateLevel.bestSpeed);
    }
    encoder.addArchiveFile(
      ArchiveFile.string(
        _windowsBundleManifestName,
        jsonEncode(<String, Object?>{
          'schema': 1,
          'platform': AppUpdatePlatform.windows.name,
          'version': version.version,
          'buildNumber': version.buildNumber,
          'files': files.map((entry) => entry.relativePath).toList(growable: false),
        }),
      ),
    );
    await encoder.close();
    opened = false;
  } finally {
    if (opened) await encoder.close().catchError((_) {});
  }
  if (!await archive.exists() || await archive.length() <= 0 || await archive.length() > appUpdateMaxPackageBytes) {
    throw StateError('app_update_package_size_invalid');
  }
}

/// Parses Gradle's output metadata instead of borrowing the Windows app version for an APK.
@visibleForTesting
AppVersionInfo? parseAndroidOutputMetadata(String source) {
  try {
    final raw = jsonDecode(source);
    final elements = raw is Map ? raw['elements'] : null;
    if (elements is! List || elements.isEmpty || elements.first is! Map) return null;
    final element = elements.first as Map;
    final version = element['versionName'];
    final buildNumber = element['versionCode'];
    if (version is! String ||
        version.trim().isEmpty ||
        version.trim().length > 128 ||
        buildNumber is! int ||
        buildNumber < 0 ||
        buildNumber > 2147483647) {
      return null;
    }
    return AppVersionInfo(platform: AppUpdatePlatform.android, version: version.trim(), buildNumber: buildNumber);
  } on Object {
    return null;
  }
}

/// Looks only at the fixed Flutter release APK and the adjacent Gradle metadata path.
@visibleForTesting
Future<DebugReleaseApk?> locateDebugReleaseApk(Iterable<Directory> roots) async {
  for (final root in roots) {
    final apk = File(
      '${root.path}${Platform.pathSeparator}build${Platform.pathSeparator}app${Platform.pathSeparator}outputs${Platform.pathSeparator}flutter-apk${Platform.pathSeparator}app-release.apk',
    );
    final metadata = File(
      '${root.path}${Platform.pathSeparator}build${Platform.pathSeparator}app${Platform.pathSeparator}outputs${Platform.pathSeparator}apk${Platform.pathSeparator}release${Platform.pathSeparator}output-metadata.json',
    );
    if (!await apk.exists() || !await metadata.exists()) continue;
    final version = parseAndroidOutputMetadata(await metadata.readAsString());
    if (version != null) return DebugReleaseApk(apk, version);
  }
  return null;
}

/// Restricts the updater to the exact runner executable directory, never a drive/root folder.
@visibleForTesting
bool isSafeWindowsUpdateTarget(File executable) {
  final absolute = executable.absolute;
  final target = absolute.parent.absolute;
  return absolute.uri.pathSegments.last.toLowerCase() == 'mg_read.exe' && target.parent.path != target.path;
}

/// Arguments are separate values, preventing PowerShell command-string interpolation.
@visibleForTesting
List<String> windowsUpdaterArguments({
  required File script,
  required File package,
  required Directory target,
  required File executable,
  required int processId,
  required String expectedChecksum,
}) => <String>[
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  script.path,
  '-Package',
  package.absolute.path,
  '-Target',
  target.absolute.path,
  '-Executable',
  executable.absolute.path,
  '-ProcessId',
  processId.toString(),
  '-ExpectedChecksum',
  expectedChecksum,
];

bool _isSafeBundleFilePath(String path) {
  if (path.isEmpty || path.length > 512 || path.startsWith('/') || path.contains('\\') || path.contains(':')) return false;
  return path.split('/').every((segment) => segment.isNotEmpty && segment != '.' && segment != '..');
}

const String _windowsUpdaterScript = r'''
param(
  [Parameter(Mandatory=$true)][string]$Package,
  [Parameter(Mandatory=$true)][string]$Target,
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(Mandatory=$true)][int]$ProcessId,
  [Parameter(Mandatory=$true)][string]$ExpectedChecksum
)
$ErrorActionPreference = 'Stop'
$maxFiles = 4096
[Int64]$maxBytes = 1610612736
$manifestName = '.mgread-bundle.json'

function Stop-Update([string]$Code) { throw $Code }
function Test-RelativeBundleFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 512 -or [IO.Path]::IsPathRooted($Path) -or $Path.Contains(':')) { return $false }
  $normalized = $Path.Replace('\\', '/')
  if ($normalized.StartsWith('/') -or $normalized.EndsWith('/')) { return $false }
  foreach ($part in $normalized.Split('/')) {
    if ([string]::IsNullOrWhiteSpace($part) -or $part -eq '.' -or $part -eq '..') { return $false }
  }
  return $true
}
function Get-ManifestFiles($Manifest) {
  if ($null -eq $Manifest -or $Manifest.schema -ne 1 -or $Manifest.platform -ne 'windows' -or $Manifest.version -isnot [string] -or $Manifest.version.Length -eq 0 -or $Manifest.version.Length -gt 128 -or $Manifest.buildNumber -isnot [Int64] -or $null -eq $Manifest.files) {
    Stop-Update 'app_update_windows_manifest_invalid'
  }
  $result = @()
  foreach ($item in @($Manifest.files)) {
    if ($item -isnot [string] -or !(Test-RelativeBundleFile $item)) { Stop-Update 'app_update_windows_manifest_invalid' }
    $result += $item.Replace('\\', '/')
  }
  if ($result.Count -eq 0 -or $result.Count -gt $maxFiles -or $result -notcontains 'mg_read.exe' -or -not ($result | Where-Object { $_.StartsWith('data/flutter_assets/', [StringComparison]::OrdinalIgnoreCase) })) {
    Stop-Update 'app_update_windows_manifest_invalid'
  }
  return $result
}
function Get-OldManifestFiles([string]$Path) {
  if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  try { return Get-ManifestFiles (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return @() }
}

$stage = $null
try {
  $targetPath = [IO.Path]::GetFullPath($Target)
  $exePath = [IO.Path]::GetFullPath($Executable)
  if ([IO.Path]::GetFileName($exePath) -ine 'mg_read.exe' -or [IO.Path]::GetDirectoryName($exePath) -ne $targetPath -or [IO.Path]::GetPathRoot($targetPath) -eq $targetPath -or !(Test-Path -LiteralPath $exePath -PathType Leaf)) { Stop-Update 'app_update_windows_target_invalid' }
  if (!(Test-Path -LiteralPath $Package -PathType Leaf) -or [IO.Path]::GetExtension($Package) -ine '.zip' -or $ExpectedChecksum -notmatch '^[a-f0-9]{8}$') { Stop-Update 'app_update_windows_package_invalid' }
  $crcTable = New-Object 'UInt32[]' 256
  for ($i = 0; $i -lt 256; $i++) {
    [UInt32]$value = [UInt32]$i
    for ($bit = 0; $bit -lt 8; $bit++) {
      $value = if (($value -band 1) -ne 0) { ($value -shr 1) -bxor [UInt32]0xEDB88320 } else { $value -shr 1 }
    }
    $crcTable[$i] = $value
  }
  $stream = [IO.File]::OpenRead($Package)
  try {
    [UInt32]$crc = [UInt32]0xFFFFFFFF
    $buffer = New-Object byte[] (1024 * 1024)
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      for ($i = 0; $i -lt $read; $i++) { $crc = ($crc -shr 8) -bxor $crcTable[($crc -bxor $buffer[$i]) -band 0xFF] }
    }
    $actualChecksum = ((($crc -bxor [UInt32]0xFFFFFFFF)).ToString('x8'))
  } finally { $stream.Dispose() }
  if ($actualChecksum -ne $ExpectedChecksum) { Stop-Update 'app_update_hash_mismatch' }
  Wait-Process -Id $ProcessId -ErrorAction SilentlyContinue
  $stage = Join-Path ([IO.Path]::GetTempPath()) ('mgread-update-stage-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($Package)
  try {
    $entries = @($zip.Entries)
    if ($entries.Count -lt 2 -or $entries.Count -gt ($maxFiles + 1)) { Stop-Update 'app_update_windows_archive_invalid' }
    [Int64]$uncompressed = 0
    $entryNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifestEntry = $null
    foreach ($entry in $entries) {
      $name = $entry.FullName.Replace('\\', '/')
      if ($name -eq $manifestName) { if ($null -ne $manifestEntry) { Stop-Update 'app_update_windows_archive_invalid' }; $manifestEntry = $entry; continue }
      if (!(Test-RelativeBundleFile $name) -or !$entryNames.Add($name)) { Stop-Update 'app_update_windows_archive_invalid' }
      $uncompressed += [Int64]$entry.Length
      if ($uncompressed -gt $maxBytes) { Stop-Update 'app_update_windows_archive_too_large' }
    }
    if ($null -eq $manifestEntry) { Stop-Update 'app_update_windows_archive_invalid' }
    $reader = [IO.StreamReader]::new($manifestEntry.Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    $newFiles = @(Get-ManifestFiles $manifest)
    if ($newFiles.Count -ne $entryNames.Count) { Stop-Update 'app_update_windows_manifest_invalid' }
    foreach ($name in $newFiles) { if (!$entryNames.Contains($name)) { Stop-Update 'app_update_windows_manifest_invalid' } }
  } finally { $zip.Dispose() }
  [IO.Compression.ZipFile]::ExtractToDirectory($Package, $stage)
  $stageExe = Join-Path $stage 'mg_read.exe'
  $stageAssets = Join-Path $stage 'data\\flutter_assets'
  if (!(Test-Path -LiteralPath $stageExe -PathType Leaf) -or !(Test-Path -LiteralPath $stageAssets -PathType Container)) { Stop-Update 'app_update_windows_bundle_invalid' }
  $oldFiles = @(Get-OldManifestFiles (Join-Path $targetPath $manifestName))
  $newSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in $newFiles) { [void]$newSet.Add($name) }
  foreach ($name in $oldFiles) {
    if (!$newSet.Contains($name)) {
      $obsolete = [IO.Path]::GetFullPath((Join-Path $targetPath $name))
      if (!$obsolete.StartsWith($targetPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Stop-Update 'app_update_windows_target_invalid' }
      if (Test-Path -LiteralPath $obsolete -PathType Leaf) { Remove-Item -LiteralPath $obsolete -Force }
    }
  }
  foreach ($name in $newFiles) {
    $source = [IO.Path]::GetFullPath((Join-Path $stage $name))
    $destination = [IO.Path]::GetFullPath((Join-Path $targetPath $name))
    if (!$source.StartsWith($stage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or !$destination.StartsWith($targetPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $source -PathType Leaf)) { Stop-Update 'app_update_windows_bundle_invalid' }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    [IO.File]::Copy($source, $destination, $true)
  }
  [IO.File]::Copy((Join-Path $stage $manifestName), (Join-Path $targetPath $manifestName), $true)
  Start-Process -FilePath $exePath -WorkingDirectory $targetPath
} catch {
  # A bounded stable code is retained beside this bootstrap script for post-restart diagnosis.
  $code = if ($_.Exception.Message -match '^app_update_[a-z0-9_]+$') { $_.Exception.Message } else { 'app_update_windows_updater_failed' }
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'update-error.txt'), $code + [Environment]::NewLine, [Text.Encoding]::ASCII)
  exit 20
} finally {
  if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $Package -PathType Leaf) { Remove-Item -LiteralPath $Package -Force -ErrorAction SilentlyContinue }
}
''';
