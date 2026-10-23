/// 漫画图片内存策略；系统只提供快照，解码与编码缓存各自保持独立有界。
/// 预算是按需使用的上限，不预分配内存，也不修改 Flutter 全局 ImageCache。
library;

import 'dart:math' as math;

import '../../platform/reader_platform.dart';

class ComicImageMemoryPolicy {
  const ComicImageMemoryPolicy({
    required this.decodedBytes,
    required this.singleImageDecodedBytes,
    required this.encodedCacheBytes,
  });

  static const int mib = 1024 * 1024;
  static const fallback = ComicImageMemoryPolicy(
    decodedBytes: 128 * mib,
    singleImageDecodedBytes: 32 * mib,
    encodedCacheBytes: 32 * mib,
  );
  static const pressure = ComicImageMemoryPolicy(
    decodedBytes: 32 * mib,
    singleImageDecodedBytes: 8 * mib,
    encodedCacheBytes: 8 * mib,
  );

  factory ComicImageMemoryPolicy.forDevice(ReaderDeviceMemoryInfo memory) {
    if (memory.lowMemory || memory.availableBytes < 256 * mib) return pressure;
    // 1/32 of physical RAM, further bounded by 1/8 of currently available
    // memory. A snapshot is only a ceiling estimate, never an allocation claim.
    int decoded = (memory.totalPhysicalBytes ~/ 32).clamp(64 * mib, 512 * mib);
    decoded = math.min(decoded, memory.availableBytes ~/ 8);
    if (memory.lowRamDevice) decoded = math.min(decoded, 64 * mib);
    if (memory.addressBits == 32) decoded = math.min(decoded, 128 * mib);
    decoded = ((decoded ~/ (16 * mib)) * 16 * mib).clamp(32 * mib, 512 * mib);
    return ComicImageMemoryPolicy(
      decodedBytes: decoded,
      singleImageDecodedBytes: decoded ~/ 4,
      encodedCacheBytes: (decoded ~/ 4).clamp(8 * mib, 128 * mib),
    );
  }

  final int decodedBytes;
  final int singleImageDecodedBytes;
  final int encodedCacheBytes;
  int get maximumPixels => decodedBytes ~/ 4;
  int get maximumImagePixels => singleImageDecodedBytes ~/ 4;
}
