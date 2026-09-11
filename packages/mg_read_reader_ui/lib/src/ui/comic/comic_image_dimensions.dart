/// Header-only image dimensions; no decoding, IO or retained byte buffers.
library;

import 'dart:typed_data';

double? comicEncodedAspectRatio(Uint8List bytes) {
  if (_isPng(bytes)) {
    return _ratio(_bigEndian32(bytes, 16), _bigEndian32(bytes, 20));
  }
  if (_isGif(bytes)) {
    return _ratio(_littleEndian(bytes, 6), _littleEndian(bytes, 8));
  }
  final double? webp = _webpAspectRatio(bytes);
  if (webp != null) return webp;
  return _jpegAspectRatio(bytes);
}

bool _isPng(Uint8List bytes) =>
    bytes.length >= 24 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47 &&
    bytes[12] == 0x49 &&
    bytes[13] == 0x48 &&
    bytes[14] == 0x44 &&
    bytes[15] == 0x52;

bool _isGif(Uint8List bytes) =>
    bytes.length >= 10 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46;

double? _webpAspectRatio(Uint8List bytes) {
  if (bytes.length < 20 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x45 ||
      bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    return null;
  }
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final int chunkLength = _littleEndian32(bytes, offset + 4);
    final int data = offset + 8;
    if (chunkLength < 0 || data + chunkLength > bytes.length) return null;
    if (_matches(bytes, offset, 'VP8X') && chunkLength >= 10) {
      return _ratio(
        1 + _littleEndian24(bytes, data + 4),
        1 + _littleEndian24(bytes, data + 7),
      );
    }
    if (_matches(bytes, offset, 'VP8 ') &&
        chunkLength >= 10 &&
        bytes[data + 3] == 0x9D &&
        bytes[data + 4] == 0x01 &&
        bytes[data + 5] == 0x2A) {
      return _ratio(
        _littleEndian(bytes, data + 6) & 0x3FFF,
        _littleEndian(bytes, data + 8) & 0x3FFF,
      );
    }
    if (_matches(bytes, offset, 'VP8L') &&
        chunkLength >= 5 &&
        bytes[data] == 0x2F) {
      final int width = 1 + bytes[data + 1] + ((bytes[data + 2] & 0x3F) << 8);
      final int height =
          1 +
          (bytes[data + 2] >> 6) +
          (bytes[data + 3] << 2) +
          ((bytes[data + 4] & 0x0F) << 10);
      return _ratio(width, height);
    }
    offset = data + chunkLength + (chunkLength.isOdd ? 1 : 0);
  }
  return null;
}

bool _matches(Uint8List bytes, int offset, String value) {
  if (offset + value.length > bytes.length) return false;
  for (var index = 0; index < value.length; index++) {
    if (bytes[offset + index] != value.codeUnitAt(index)) return false;
  }
  return true;
}

double? _jpegAspectRatio(Uint8List bytes) {
  if (bytes.length < 9 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var offset = 2;
  while (offset + 8 < bytes.length) {
    if (bytes[offset] != 0xFF) {
      offset++;
      continue;
    }
    while (offset < bytes.length && bytes[offset] == 0xFF) {
      offset++;
    }
    if (offset >= bytes.length) return null;
    final int marker = bytes[offset++];
    if (marker == 0xD8 || marker == 0xD9) continue;
    if (offset + 1 >= bytes.length) return null;
    final int length = _unsignedShort(bytes, offset);
    if (length < 2 || offset + length > bytes.length) return null;
    if ((marker >= 0xC0 && marker <= 0xC3) ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF)) {
      return _ratio(
        _unsignedShort(bytes, offset + 5),
        _unsignedShort(bytes, offset + 3),
      );
    }
    offset += length;
  }
  return null;
}

int _bigEndian32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _unsignedShort(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _littleEndian(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _littleEndian24(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

int _littleEndian32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

double? _ratio(int width, int height) => width <= 0 || height <= 0
    ? null
    : (width / height).clamp(.02, 20).toDouble();
