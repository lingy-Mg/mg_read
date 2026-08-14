import 'dart:typed_data';

/// Small incremental SHA-256 implementation used for diagnostic object
/// integrity and content addressing. It is not a key-derivation primitive.
final class DiagnosticSha256 {
  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  final Uint32List _state = Uint32List.fromList(<int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);
  final Uint8List _pending = Uint8List(64);
  var _pendingLength = 0;
  var _totalLength = 0;
  var _finished = false;

  void add(List<int> bytes) {
    if (_finished) throw StateError('SHA-256 digest is already finalized.');
    _totalLength += bytes.length;
    var offset = 0;
    if (_pendingLength > 0) {
      final needed = 64 - _pendingLength;
      final copied = bytes.length < needed ? bytes.length : needed;
      _pending.setRange(_pendingLength, _pendingLength + copied, bytes, offset);
      _pendingLength += copied;
      offset += copied;
      if (_pendingLength == 64) {
        _processBlock(_pending, 0);
        _pendingLength = 0;
      }
    }
    while (offset + 64 <= bytes.length) {
      _processBlock(bytes, offset);
      offset += 64;
    }
    if (offset < bytes.length) {
      final remaining = bytes.length - offset;
      _pending.setRange(0, remaining, bytes, offset);
      _pendingLength = remaining;
    }
  }

  String closeHex() {
    if (_finished) throw StateError('SHA-256 digest is already finalized.');
    _finished = true;
    final bitLength = _totalLength * 8;
    final paddingLength = _pendingLength < 56
        ? 64 - _pendingLength
        : 128 - _pendingLength;
    final padding = Uint8List(paddingLength);
    padding[0] = 0x80;
    for (var index = 0; index < 8; index += 1) {
      padding[paddingLength - 1 - index] = (bitLength >> (index * 8)) & 0xff;
    }
    var offset = 0;
    final firstNeeded = 64 - _pendingLength;
    _pending.setRange(_pendingLength, 64, padding, 0);
    _processBlock(_pending, 0);
    offset += firstNeeded;
    if (offset < padding.length) {
      _processBlock(padding, offset);
    }
    return _state.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
  }

  void _processBlock(List<int> block, int offset) {
    final words = Uint32List(64);
    for (var index = 0; index < 16; index += 1) {
      final start = offset + index * 4;
      words[index] =
          ((block[start] & 0xff) << 24) |
          ((block[start + 1] & 0xff) << 16) |
          ((block[start + 2] & 0xff) << 8) |
          (block[start + 3] & 0xff);
    }
    for (var index = 16; index < 64; index += 1) {
      final s0 =
          _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final s1 =
          _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] =
          (words[index - 16] + s0 + words[index - 7] + s1) & 0xffffffff;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];

    for (var index = 0; index < 64; index += 1) {
      final upperSigma1 =
          _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temp1 =
          (h + upperSigma1 + choose + _roundConstants[index] + words[index]) &
          0xffffffff;
      final upperSigma0 =
          _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (upperSigma0 + majority) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
    _state[4] = (_state[4] + e) & 0xffffffff;
    _state[5] = (_state[5] + f) & 0xffffffff;
    _state[6] = (_state[6] + g) & 0xffffffff;
    _state[7] = (_state[7] + h) & 0xffffffff;
  }

  int _rotateRight(int value, int count) =>
      ((value >> count) | (value << (32 - count))) & 0xffffffff;
}
