/// Typed update outcomes and persisted automatic-check timing. No IO is owned
/// here. Hosts supply storage and a clock; failures never count as success.
library;

enum UpdateCheckStatus { available, upToDate, failed, skipped, unsupported }

final class UpdateCheckResult<T> {
  const UpdateCheckResult(this.status, {this.value, this.error});
  final UpdateCheckStatus status;
  final T? value;
  final Object? error;
  String get message => switch (status) {
    UpdateCheckStatus.available => '发现新版本。',
    UpdateCheckStatus.upToDate => '当前已是最新版本。',
    UpdateCheckStatus.failed => '检查更新失败，请检查网络后重试。',
    UpdateCheckStatus.skipped => '尚未到自动检查时间。',
    UpdateCheckStatus.unsupported => '当前平台不支持此更新方式。',
  };
}

final class AutomaticCheckTiming {
  DateTime? attemptedAt;
  DateTime? succeededAt;
  int failures = 0;

  bool isDue(DateTime now, Duration interval) {
    final last = failures > 0 ? attemptedAt : succeededAt;
    if (last == null || now.isBefore(last)) return true;
    final wait = failures > 0
        ? Duration(
            minutes: failures == 1
                ? 1
                : failures == 2
                ? 5
                : 30,
          )
        : interval;
    return now.difference(last) >= wait;
  }

  void complete(DateTime now, {required bool success}) {
    attemptedAt = now;
    if (success) {
      succeededAt = now;
      failures = 0;
    } else {
      failures++;
    }
  }

  Map<String, Object?> toJson() => {
    'attemptedAt': attemptedAt?.toUtc().toIso8601String(),
    'succeededAt': succeededAt?.toUtc().toIso8601String(),
    'failures': failures,
  };

  void restore(Map<String, Object?> json) {
    attemptedAt = DateTime.tryParse('${json['attemptedAt']}');
    succeededAt = DateTime.tryParse('${json['succeededAt']}');
    final value = json['failures'];
    failures = value is int && value > 0 ? value : 0;
  }
}
