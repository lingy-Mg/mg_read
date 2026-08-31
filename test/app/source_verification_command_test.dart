import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/source_verification_command.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

void main() {
  test('ignores ordinary app arguments and parses one source command', () {
    expect(parseSourceVerificationCommand(const <String>[]), isNull);

    final command = parseSourceVerificationCommand(const <String>[
      '--source-check=org.mgread.fixture',
      '--source-check-report=fixture-report.json',
    ], currentDirectory: 'C:\\workspace');

    expect(command, isNotNull);
    expect(command!.pluginId, 'org.mgread.fixture');
    expect(command.all, isFalse);
    expect(command.reportPath, endsWith('fixture-report.json'));
  });

  test('parses all-sources mode and rejects ambiguous selection', () {
    final command = parseSourceVerificationCommand(const <String>['--source-check-all'], currentDirectory: 'C:\\workspace');
    expect(command!.all, isTrue);
    expect(command.reportPath, endsWith('mgread-source-verification.json'));

    expect(
      () => parseSourceVerificationCommand(const <String>['--source-check-all', '--source-check', 'org.mgread.fixture']),
      throwsA(isA<SourceVerificationRunException>()),
    );
  });
}
