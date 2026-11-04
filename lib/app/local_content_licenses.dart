/// Registers bundled encoding-table attribution with Flutter's license page.
/// Registration is synchronous; notice bytes load only when licenses are read.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerLocalContentLicenses() {
  if ((Platform.isWindows || Platform.isMacOS) && !const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) {
    LicenseRegistry.addLicense(() async* {
      final platform = Platform.isWindows ? 'windows-x64' : 'macos-arm64';
      final notice = await rootBundle.loadString('packages/mgread_plugin_runtime/assets/runtime/$platform/node/BUN-LICENSE.md');
      yield LicenseEntryWithLineBreaks(const ['Bun 1.4.4 and bundled libraries'], notice);
    });
  }
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString('lib/core/local_documents/encoding/NOTICE.md');
    yield LicenseEntryWithLineBreaks(const ['WHATWG GB18030 encoding tables'], notice);
  });
}
