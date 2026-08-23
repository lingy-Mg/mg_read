/// App-owned reading totals rendered in the existing profile summary card.
final class ProfileReadingStats {
  const ProfileReadingStats({
    required this.totalReadingSeconds,
    required this.readBookCount,
    required this.shelfBookCount,
  }) : assert(totalReadingSeconds >= 0),
       assert(readBookCount >= 0),
       assert(shelfBookCount >= 0);

  final int totalReadingSeconds;
  final int readBookCount;
  final int shelfBookCount;
}
