/// 已配对同步传输层公开结果和内部错误类型。
part of 'paired_sync_transport.dart';

final class PairedSyncEndpoint {
  const PairedSyncEndpoint({
    required this.address,
    required this.deviceId,
    required this.expiresAtUtc,
    required this.label,
    required this.port,
    this.appOffers = const <AppPackageOffer>[],
  });

  final String address;
  final String deviceId;
  final DateTime expiresAtUtc;
  final String label;
  final int port;
  final List<AppPackageOffer> appOffers;
}

final class PairedSyncRunSummary {
  const PairedSyncRunSummary({
    required this.receivedBooks,
    required this.receivedPlugins,
    required this.sentBooks,
    required this.sentPlugins,
    required this.developmentConflicts,
    this.skippedShelfItems = 0,
  });

  const PairedSyncRunSummary.empty()
    : receivedBooks = 0,
      receivedPlugins = 0,
      sentBooks = 0,
      sentPlugins = 0,
      developmentConflicts = 0,
      skippedShelfItems = 0;

  final int receivedBooks;
  final int receivedPlugins;
  final int sentBooks;
  final int sentPlugins;
  final int developmentConflicts;
  final int skippedShelfItems;
}

final class PairedSyncPartialException implements Exception {
  const PairedSyncPartialException(this.cause, {required this.stage, required this.causeStackTrace});

  final Object cause;
  final String stage;
  final StackTrace causeStackTrace;
}

final class PairedSyncPeerFailureException implements Exception {
  const PairedSyncPeerFailureException({required this.code, required this.stage, required this.errorText});

  final String code;
  final String stage;
  final String errorText;
}

typedef PairedSyncStageObserver = void Function(String stage);
