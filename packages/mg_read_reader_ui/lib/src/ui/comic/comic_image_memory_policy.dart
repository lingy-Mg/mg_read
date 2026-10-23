/// 漫画图片内存策略：4GB 及以下设备统一给 500 MiB，
/// 超过 4GB 取消总解码与单图解码软上限（null）；编码缓存仍保持有界。
/// 物理内存向上取整至 GiB 以容纳系统预留；压力状态优先临时收缩。
/// 预算按需使用，不预分配内存，也不修改 Flutter 全局 ImageCache。
library;

import '../../platform/reader_platform.dart';

class ComicImageMemoryPolicy {
  const ComicImageMemoryPolicy({
    required this.decodedBytes,
    required this.singleImageDecodedBytes,
    required this.encodedCacheBytes,
  });

  static const int mib = 1024 * 1024;
  static const fallback = ComicImageMemoryPolicy(
    decodedBytes: 500 * mib,
    singleImageDecodedBytes: 125 * mib,
    encodedCacheBytes: 125 * mib,
  );
  static const pressure = ComicImageMemoryPolicy(
    decodedBytes: 32 * mib,
    singleImageDecodedBytes: 8 * mib,
    encodedCacheBytes: 8 * mib,
  );

  factory ComicImageMemoryPolicy.forDevice(ReaderDeviceMemoryInfo memory) {
    if (memory.lowMemory || memory.availableBytes < 256 * mib) return pressure;
    const int gib = 1024 * mib;
    final int deviceGiB = (memory.totalPhysicalBytes + gib - 1) ~/ gib;
    if (deviceGiB > 4) {
      return const ComicImageMemoryPolicy(
        decodedBytes: null,
        singleImageDecodedBytes: null,
        encodedCacheBytes: 128 * mib,
      );
    }
    return fallback;
  }

  final int? decodedBytes;
  final int? singleImageDecodedBytes;
  final int encodedCacheBytes;
  int? get maximumPixels => decodedBytes == null ? null : decodedBytes! ~/ 4;
  int? get maximumImagePixels =>
      singleImageDecodedBytes == null ? null : singleImageDecodedBytes! ~/ 4;
}
