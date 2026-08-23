import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/profile/domain/profile_reading_stats.dart';

/// Application port for the locally persisted profile reading totals.
abstract interface class ProfileReadingStatsLoader {
  Future<ProfileReadingStats> load();
}

/// Isolated presentation tests have no app-owned Content Library.
final class EmptyProfileReadingStatsLoader
    implements ProfileReadingStatsLoader {
  const EmptyProfileReadingStatsLoader();

  @override
  Future<ProfileReadingStats> load() async => const ProfileReadingStats(
    totalReadingSeconds: 0,
    readBookCount: 0,
    shelfBookCount: 0,
  );
}

final profileReadingStatsLoaderProvider = Provider<ProfileReadingStatsLoader>(
  (Ref ref) => const EmptyProfileReadingStatsLoader(),
);

/// Cached until the profile route is recreated; it never calls Runtime.
final profileReadingStatsProvider = FutureProvider<ProfileReadingStats>(
  (Ref ref) => ref.watch(profileReadingStatsLoaderProvider).load(),
);
