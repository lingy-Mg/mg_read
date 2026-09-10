import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/source_verification_command.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

void main() {
  test('ignores ordinary app arguments and parses one source command', () {
    expect(parseSourceVerificationCommand(const <String>[]), isNull);

    final command = parseSourceVerificationCommand(const <String>['--source-check=org.mgread.fixture']);

    expect(command, isNotNull);
    expect(command!.pluginId, 'org.mgread.fixture');
    expect(command.all, isFalse);
  });

  test('parses all-sources mode and rejects ambiguous selection', () {
    final command = parseSourceVerificationCommand(const <String>['--source-check-all']);
    expect(command!.all, isTrue);

    expect(
      () => parseSourceVerificationCommand(const <String>['--source-check-all', '--source-check', 'org.mgread.fixture']),
      throwsA(isA<SourceVerificationRunException>()),
    );
  });

  test('keeps the selected source id without a report path', () {
    final command = parseSourceVerificationCommand(const <String>['--source-check', 'org.mgread.diyibanzhu-me']);

    expect(command!.pluginId, 'org.mgread.diyibanzhu-me');
    expect(command.all, isFalse);
    expect(command.reportPath, isNull);
  });

  test('parses an optional local report path with the source command', () {
    final command = parseSourceVerificationCommand(const <String>[
      '--source-check=org.mgread.fixture',
      '--source-check-report',
      r'C:\Temp\source-report.json',
    ]);

    expect(command!.pluginId, 'org.mgread.fixture');
    expect(command.reportPath, r'C:\Temp\source-report.json');
    expect(command.traceReportPath, isNull);
  });

  test('parses an optional trace path for an explicitly requested CLI diagnostic', () {
    final command = parseSourceVerificationCommand(const <String>[
      '--source-check=org.mgread.fixture',
      '--source-check-trace-report=C:\\Temp\\source-trace.json',
    ]);

    expect(command!.traceReportPath, r'C:\Temp\source-trace.json');
  });
}
