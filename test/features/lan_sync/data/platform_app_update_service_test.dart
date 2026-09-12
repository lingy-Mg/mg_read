/// Windows/App-version package boundary tests.
///
/// These tests build only temporary runner bundles and inject the external updater
/// launcher. They never start PowerShell, terminate Dart, overwrite a runner, or
/// use an installed Android package.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/platform_app_update_service.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('mgread-platform-app-update-test-');
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('Gradle output metadata provides the APK own version and build number', () {
    final version = parseAndroidOutputMetadata('''
      {"elements":[{"versionCode":321,"versionName":"2.4.6"}]}
    ''');

    expect(version, isNotNull);
    expect(version!.platform, AppUpdatePlatform.android);
    expect(version.version, '2.4.6');
    expect(version.buildNumber, 321);
    expect(parseAndroidOutputMetadata('{"elements":[{"versionCode":"321","versionName":"2.4.6"}]}'), isNull);
    expect(parseAndroidOutputMetadata('{"elements":[{"versionCode":321,"versionName":"  "}]}'), isNull);
  });

  test('debug APK discovery requires the fixed APK and adjacent Gradle metadata', () async {
    final root = Directory('${temporary.path}${Platform.pathSeparator}project');
    final apk = File(
      '${root.path}${Platform.pathSeparator}build${Platform.pathSeparator}app${Platform.pathSeparator}outputs${Platform.pathSeparator}flutter-apk${Platform.pathSeparator}app-release.apk',
    );
    final metadata = File(
      '${root.path}${Platform.pathSeparator}build${Platform.pathSeparator}app${Platform.pathSeparator}outputs${Platform.pathSeparator}apk${Platform.pathSeparator}release${Platform.pathSeparator}output-metadata.json',
    );
    await apk.parent.create(recursive: true);
    await metadata.parent.create(recursive: true);
    await apk.writeAsBytes(<int>[1, 2, 3]);
    await metadata.writeAsString('{"elements":[{"versionCode":88,"versionName":"1.8.0"}]}');

    final discovered = await locateDebugReleaseApk(<Directory>[root]);

    expect(discovered?.file.path, apk.path);
    expect(discovered?.version.displayVersion, '1.8.0 (88)');
  });

  test('Windows bundle ZIP is bounded to static regular files and retains actual version metadata', () async {
    final bundle = await _writeRunnerBundle(temporary);
    final files = await collectWindowsBundleFiles(bundle);
    final archive = File('${temporary.path}${Platform.pathSeparator}bundle.zip');
    const version = AppVersionInfo(platform: AppUpdatePlatform.windows, version: '3.2.1', buildNumber: 44);

    await createWindowsBundleArchive(archive: archive, version: version, files: files);

    final decoded = ZipDecoder().decodeBytes(await archive.readAsBytes(), verify: true);
    final manifest = decoded.find('.mgread-bundle.json');
    final metadata = jsonDecode(utf8.decode(manifest!.content)) as Map<String, Object?>;
    expect(files.map((file) => file.relativePath), containsAll(<String>['mg_read.exe', 'data/flutter_assets/app.so']));
    expect(decoded.find('mg_read.exe'), isNotNull);
    expect(decoded.find('data/flutter_assets/app.so'), isNotNull);
    expect(metadata['platform'], 'windows');
    expect(metadata['version'], '3.2.1');
    expect(metadata['buildNumber'], 44);
  });

  test('injected Windows updater targets only current mg_read.exe bundle and schedules exit after launch', () async {
    final bundle = await _writeRunnerBundle(temporary);
    final executable = File('${bundle.path}${Platform.pathSeparator}mg_read.exe');
    final package = File('${temporary.path}${Platform.pathSeparator}received.zip');
    await package.writeAsBytes(<int>[4, 5, 6]);
    final descriptor = AppPackageDescriptor(
      version: const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '3.2.1', buildNumber: 44),
      bytes: await package.length(),
      checksum: lanSyncChecksum(await package.readAsBytes()),
      fileName: 'received.zip',
    );
    List<String>? arguments;
    var exitScheduled = false;
    final service = PlatformAppUpdateService(
      dependencies: PlatformAppUpdateDependencies(
        isAndroid: false,
        isWindows: true,
        isMacOS: false,
        isDebug: false,
        resolvedExecutable: executable.path,
        currentDirectory: temporary,
        processId: 123,
        startWindowsUpdater: (command, values) async {
          expect(command, 'powershell.exe');
          arguments = values;
        },
        exitAfterWindowsUpdater: () async {
          exitScheduled = true;
        },
        createTemporaryDirectory: (prefix) => temporary.createTemp(prefix),
      ),
    );

    await service.launchInstaller(package, descriptor);

    expect(exitScheduled, isTrue);
    expect(arguments, containsAllInOrder(<String>['-NoProfile', '-NonInteractive', '-File']));
    expect(
      arguments,
      containsAll(<String>[
        '-Target',
        bundle.absolute.path,
        '-Executable',
        executable.absolute.path,
        '-ExpectedChecksum',
        descriptor.checksum,
      ]),
    );
    final script = File(arguments![arguments!.indexOf('-File') + 1]);
    final source = await script.readAsString();
    expect(source, contains(r"[IO.Path]::GetFileName($exePath) -ine 'mg_read.exe'"));
    expect(source, contains('Get-ManifestFiles'));
    expect(source, contains(r'$oldFiles'));
    expect(source, isNot(contains(r'$assetTarget')));
    if (Platform.isWindows) {
      final escapedPath = script.path.replaceAll("'", "''");
      final parsed = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "[void][scriptblock]::Create([IO.File]::ReadAllText('$escapedPath'))",
      ]);
      expect(parsed.exitCode, 0, reason: parsed.stderr.toString());
    }
  });

  test('unsafe executable names are rejected before any updater launch', () async {
    final bundle = await _writeRunnerBundle(temporary);
    final unsafe = File('${bundle.path}${Platform.pathSeparator}other.exe');
    await unsafe.writeAsBytes(<int>[0]);
    final package = File('${temporary.path}${Platform.pathSeparator}received.zip');
    await package.writeAsBytes(<int>[4, 5, 6]);
    final descriptor = AppPackageDescriptor(
      version: const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '3.2.1', buildNumber: 44),
      bytes: await package.length(),
      checksum: lanSyncChecksum(await package.readAsBytes()),
      fileName: 'received.zip',
    );
    var launched = false;
    final service = PlatformAppUpdateService(
      dependencies: PlatformAppUpdateDependencies(
        isAndroid: false,
        isWindows: true,
        isMacOS: false,
        isDebug: false,
        resolvedExecutable: unsafe.path,
        currentDirectory: temporary,
        processId: 123,
        startWindowsUpdater: (_, _) async => launched = true,
        exitAfterWindowsUpdater: () async {},
        createTemporaryDirectory: (prefix) => temporary.createTemp(prefix),
      ),
    );

    await expectLater(service.launchInstaller(package, descriptor), throwsA(isA<StateError>()));
    expect(launched, isFalse);
  });
}

Future<Directory> _writeRunnerBundle(Directory parent) async {
  final bundle = Directory('${parent.path}${Platform.pathSeparator}runner');
  final assets = Directory('${bundle.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets');
  await assets.create(recursive: true);
  await File('${bundle.path}${Platform.pathSeparator}mg_read.exe').writeAsBytes(<int>[1, 2, 3]);
  await File('${bundle.path}${Platform.pathSeparator}flutter_windows.dll').writeAsBytes(<int>[4, 5, 6]);
  await File('${assets.path}${Platform.pathSeparator}app.so').writeAsBytes(<int>[7, 8, 9]);
  return bundle;
}
