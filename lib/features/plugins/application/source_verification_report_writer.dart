/// 数据源自检报告的本地 JSON 写入器。
///
/// 职责：把自检报告写入用户或 CLI 指定文件。
library;

import 'dart:convert';
import 'dart:io';

import 'source_verification_models.dart';

final class SourceVerificationReportWriter {
  const SourceVerificationReportWriter();

  Future<void> write(String path, SourceVerificationReport report) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    await target.writeAsString('${const JsonEncoder.withIndent('  ').convert(report.toJson())}\n', flush: true);
  }
}
