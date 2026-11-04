/// Registers bundled encoding-table attribution with Flutter's license page.
/// Registration is synchronous; notice bytes load only when licenses are read.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerLocalContentLicenses() {
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString('lib/core/local_documents/encoding/NOTICE.md');
    yield LicenseEntryWithLineBreaks(const ['WHATWG GB18030 encoding tables'], notice);
  });
}
