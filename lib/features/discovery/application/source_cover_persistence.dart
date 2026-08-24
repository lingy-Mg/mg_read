import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Resolves a source cover through the app-owned persistent cover store.
///
/// The port is deliberately independent of Runtime transport and returns only
/// display bytes. A missing or failed cover must resolve to null so search and
/// discovery content remain usable with a deterministic placeholder.
abstract interface class SourceCoverPersistence {
  Future<List<int>?> resolve({
    required String pluginId,
    String pluginVersion = 'unknown',
    required String remoteContentId,
    required Uri? coverUrl,
  });
}

final class EmptySourceCoverPersistence implements SourceCoverPersistence {
  const EmptySourceCoverPersistence();

  @override
  Future<List<int>?> resolve({
    required String pluginId,
    String pluginVersion = 'unknown',
    required String remoteContentId,
    required Uri? coverUrl,
  }) async => null;
}

final sourceCoverPersistenceProvider = Provider<SourceCoverPersistence>(
  (Ref ref) => const EmptySourceCoverPersistence(),
);
