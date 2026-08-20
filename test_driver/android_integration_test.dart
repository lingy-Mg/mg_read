import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver_extended.dart'
    as integration_driver;

Future<void> main() async {
  final outputDirectory = Platform.environment['FLUTTER_TEST_OUTPUTS_DIR'];
  if (outputDirectory == null || outputDirectory.isEmpty) {
    throw StateError(
      'FLUTTER_TEST_OUTPUTS_DIR must be set by '
      'tools/run_android_integration_tests.ps1.',
    );
  }

  final screenshotDirectory = Directory(
    '$outputDirectory${Platform.pathSeparator}screenshots',
  );
  await screenshotDirectory.create(recursive: true);

  await integration_driver.integrationDriver(
    driver: await FlutterDriver.connect(),
    onScreenshot: (name, image, [args]) async {
      final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      await File(
        '${screenshotDirectory.path}${Platform.pathSeparator}$safeName.png',
      ).writeAsBytes(image, flush: true);
      return true;
    },
    responseDataCallback: (data) => integration_driver.writeResponseData(
      data,
      destinationDirectory: outputDirectory,
    ),
    writeResponseOnFailure: true,
  );
}
