// Owns one authenticated phone-to-TV WebSocket session. The caller owns peer
// authorization and the long-term PSK; this class keeps only derived session
// keys, bounds all JSON frames, and closes the socket on protocol failure.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'companion_secure_handshake.dart';

typedef CompanionJson = Map<String, Object?>;

const int _maxPlaintextBytes = 64 * 1024;
const int _frameHeaderLength = 21;
const int _tagLength = 16;

/// A deliberately non-descriptive public error; peer material and crypto
/// failure details must not escape into UI/logging by default.
final class CompanionSecureChannelException implements Exception {
  const CompanionSecureChannelException();

  @override
  String toString() => 'Companion secure channel failed';
}

final class CompanionSecureChannel {
  CompanionSecureChannel._({
    required this._socket,
    required this._inbox,
    this._httpClient,
    required this.peerDeviceId,
    required this.sessionId,
    required this._sendKey,
    required this._receiveKey,
    required this._sendNoncePrefix,
    required this._receiveNoncePrefix,
    required this._sendDirection,
    required this._receiveDirection,
  }) {
    _inbox.start(_onSocketData, _onSocketError, _onSocketDone);
  }

  final WebSocket _socket;
  final _SocketInbox _inbox;
  final HttpClient? _httpClient;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final List<int> _sendNoncePrefix;
  final List<int> _receiveNoncePrefix;
  final String _sendDirection;
  final String _receiveDirection;
  late final StreamController<CompanionJson> _messages = StreamController<CompanionJson>(
    onListen: () {
      _businessConsumerReady = true;
      _undeliveredMessages = 0;
    },
    onPause: () {
      _businessConsumerReady = false;
    },
    onResume: () {
      _businessConsumerReady = true;
      _undeliveredMessages = 0;
    },
  );
  bool _businessConsumerReady = false;
  int _undeliveredMessages = 0, _pendingSends = 0, _pendingReceives = 0;

  /// Business messages received after authentication. This is single-subscribe
  /// and buffers messages received before the consumer attaches.
  Stream<CompanionJson> get messages => _messages.stream;

  final String peerDeviceId;
  final String sessionId;
  Future<void> _sendTail = Future<void>.value();
  Future<void> _receiveTail = Future<void>.value();
  int _sendSequence = 0;
  int _receiveSequence = 0;
  bool _closed = false;

  static final _aes = AesGcm.with256bits();

  static Future<CompanionSecureChannel> connect({
    required Uri uri,
    required String localDeviceId,
    required String remoteDeviceId,
    required List<int> sharedSecret,
    Duration timeout = const Duration(seconds: 5),
    bool allowLoopbackForTesting = false,
  }) async {
    _validateIds(localDeviceId, remoteDeviceId);
    _validateSecret(sharedSecret);
    _validateEndpoint(uri, allowLoopbackForTesting);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    WebSocket? socket;
    _SocketInbox? inbox;
    try {
      socket = await WebSocket.connect(uri.toString(), customClient: client).timeout(timeout);
      inbox = _SocketInbox(socket);
      final result = await CompanionSecureHandshake.client(
        localId: localDeviceId,
        remoteId: remoteDeviceId,
        secret: sharedSecret,
        send: (message) => socket!.add(utf8.decode(CompanionSecureHandshake.encodeMessage(message))),
        receive: () => inbox!.next(timeout),
        timeout: timeout,
      );
      return CompanionSecureChannel._(
        socket: socket,
        inbox: inbox,
        httpClient: client,
        peerDeviceId: remoteDeviceId,
        sessionId: result.keys.sessionId,
        sendKey: result.keys.clientToServerKey,
        receiveKey: result.keys.serverToClientKey,
        sendNoncePrefix: result.keys.clientNoncePrefix,
        receiveNoncePrefix: result.keys.serverNoncePrefix,
        sendDirection: 'client-to-server',
        receiveDirection: 'server-to-client',
      );
    } catch (_) {
      if (socket != null) await _quietClose(socket);
      if (inbox != null) await inbox.dispose();
      client.close(force: true);
      throw const CompanionSecureChannelException();
    } finally {
      if (socket == null) client.close(force: true);
    }
  }

  static Future<CompanionSecureChannel> accept({
    required WebSocket socket,
    required String localDeviceId,
    required Future<List<int>?> Function(String peerId) resolvePeerSecret,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _validateLocalId(localDeviceId);
    final inbox = _SocketInbox(socket);
    try {
      final result = await CompanionSecureHandshake.server(
        localId: localDeviceId,
        resolvePeerSecret: resolvePeerSecret,
        send: (message) => socket.add(utf8.decode(CompanionSecureHandshake.encodeMessage(message))),
        receive: () => inbox.next(timeout),
        timeout: timeout,
      );
      return CompanionSecureChannel._(
        socket: socket,
        inbox: inbox,
        peerDeviceId: result.peerId,
        sessionId: result.keys.sessionId,
        sendKey: result.keys.serverToClientKey,
        receiveKey: result.keys.clientToServerKey,
        sendNoncePrefix: result.keys.serverNoncePrefix,
        receiveNoncePrefix: result.keys.clientNoncePrefix,
        sendDirection: 'server-to-client',
        receiveDirection: 'client-to-server',
      );
    } catch (_) {
      await _quietClose(socket);
      await inbox.dispose();
      throw const CompanionSecureChannelException();
    }
  }

  Future<void> send(CompanionJson message) {
    if (_closed || _pendingSends >= 32) return Future<void>.error(const CompanionSecureChannelException());
    _pendingSends++;
    final task = _sendTail.then((_) => _sendOne(message)).whenComplete(() => _pendingSends--);
    _sendTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> _sendOne(CompanionJson message) async {
    if (_closed || _sendSequence >= 0x7FFFFFFFFFFFFFFF) {
      throw const CompanionSecureChannelException();
    }
    final plaintext = utf8.encode(jsonEncode(message));
    if (plaintext.length > _maxPlaintextBytes) {
      throw const CompanionSecureChannelException();
    }
    final sequence = _sendSequence;
    final header = _frameHeader(sequence, _sendNoncePrefix);
    final nonce = _nonce(_sendNoncePrefix, sequence);
    final aad = _associatedData(header, _sendDirection);
    final box = await _aes.encrypt(plaintext, secretKey: _sendKey, nonce: nonce, aad: aad);
    if (_closed || sequence != _sendSequence) {
      throw const CompanionSecureChannelException();
    }
    _sendSequence++;
    _socket.add(Uint8List.fromList(<int>[...header, ...box.cipherText, ...box.mac.bytes]));
  }

  void _onSocketData(dynamic value) {
    if (_closed || value is! List<int> || value.length > _frameHeaderLength + _maxPlaintextBytes + _tagLength || _pendingReceives >= 64) {
      _fail();
      return;
    }
    _pendingReceives++;
    _receiveTail = _receiveTail.then((_) => _receiveOne(value)).whenComplete(() => _pendingReceives--).catchError((Object _) => _fail());
  }

  Future<void> _receiveOne(dynamic value) async {
    if (_closed ||
        value is! List<int> ||
        value.length < _frameHeaderLength + _tagLength ||
        value.length > _frameHeaderLength + _maxPlaintextBytes + _tagLength) {
      _fail();
      return;
    }
    final bytes = List<int>.unmodifiable(value);
    if (bytes[0] != 1) {
      _fail();
      return;
    }
    final sequence = _readUint64(bytes, 1);
    if (sequence != _receiveSequence || sequence >= 0x7FFFFFFFFFFFFFFF) {
      _fail();
      return;
    }
    final header = bytes.sublist(0, _frameHeaderLength);
    final expectedNonce = _nonce(_receiveNoncePrefix, sequence);
    if (!_constantTimeEqual(bytes.sublist(9, 21), expectedNonce)) {
      _fail();
      return;
    }
    try {
      final cipherEnd = bytes.length - _tagLength;
      final box = SecretBox(bytes.sublist(_frameHeaderLength, cipherEnd), nonce: expectedNonce, mac: Mac(bytes.sublist(cipherEnd)));
      final plaintext = await _aes.decrypt(box, secretKey: _receiveKey, aad: _associatedData(header, _receiveDirection));
      if (_closed || plaintext.length > _maxPlaintextBytes) {
        _fail();
        return;
      }
      final decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map<String, dynamic>) {
        _fail();
        return;
      }
      _receiveSequence++;
      if (!_businessConsumerReady && ++_undeliveredMessages > 32) {
        _fail();
        return;
      }
      _messages.add(Map<String, Object?>.from(decoded));
    } catch (error) {
      _fail();
    }
  }

  void _onSocketError(Object error, [StackTrace? stack]) => _fail();

  void _onSocketDone() {
    unawaited(_inbox.dispose());
    _httpClient?.close(force: true);
    if (!_closed) {
      _closed = true;
      _messages.close();
    }
  }

  void _fail() {
    if (_closed) return;
    _closed = true;
    _messages.addError(const CompanionSecureChannelException());
    unawaited(_messages.close());
    unawaited(_quietClose(_socket));
    _httpClient?.close(force: true);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _quietClose(_socket);
    await _inbox.dispose();
    _httpClient?.close(force: true);
    unawaited(_messages.close());
  }

  static List<int> _frameHeader(int sequence, List<int> prefix) => <int>[1, ..._uint64(sequence), ...prefix, ..._uint64(sequence)];

  static List<int> _nonce(List<int> prefix, int sequence) => <int>[...prefix, ..._uint64(sequence)];

  static List<int> _associatedData(List<int> header, String direction) => <int>[
    ...utf8.encode('mgread-companion-frame-v1\u0000$direction\u0000'),
    ...header,
  ];

  static List<int> _uint64(int value) => <int>[
    (value >> 56) & 255,
    (value >> 48) & 255,
    (value >> 40) & 255,
    (value >> 32) & 255,
    (value >> 24) & 255,
    (value >> 16) & 255,
    (value >> 8) & 255,
    value & 255,
  ];

  static int _readUint64(List<int> bytes, int offset) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }

  static bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  static void _validateIds(String local, String remote) {
    _validateLocalId(local);
    if (remote.isEmpty || remote.length > 128 || local == remote) {
      throw const CompanionSecureChannelException();
    }
  }

  static void _validateLocalId(String id) {
    if (id.isEmpty || id.length > 128) {
      throw const CompanionSecureChannelException();
    }
  }

  static void _validateSecret(List<int> secret) {
    if (secret.length < 32 || secret.length > 128 || secret.any((b) => b < 0 || b > 255)) {
      throw const CompanionSecureChannelException();
    }
  }

  static void _validateEndpoint(Uri uri, bool allowLoopback) {
    final ip = InternetAddress.tryParse(uri.host);
    final isPrivateV4 =
        ip != null &&
        ip.type == InternetAddressType.IPv4 &&
        (ip.address.startsWith('10.') ||
            ip.address.startsWith('192.168.') ||
            _is172Private(ip.address) ||
            (allowLoopback && ip.isLoopback));
    if (uri.scheme != 'ws' || !isPrivateV4 || uri.userInfo.isNotEmpty || uri.hasFragment || uri.port < 1 || uri.port > 65535) {
      throw const CompanionSecureChannelException();
    }
  }

  static bool _is172Private(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;
    final second = int.tryParse(parts[1]);
    return int.tryParse(parts[0]) == 172 && second != null && second >= 16 && second <= 31;
  }

  static Future<void> _quietClose(WebSocket socket) async {
    try {
      await socket.close(WebSocketStatus.goingAway).timeout(const Duration(seconds: 1));
    } catch (_) {
      try {
        socket.close();
      } catch (_) {}
    }
  }
}

final class _SocketInbox {
  _SocketInbox(this._socket) {
    _subscription = _socket.listen(
      (value) {
        final size = value is String
            ? utf8.encode(value).length
            : value is List<int>
            ? value.length
            : 1 << 30;
        if (size > _frameHeaderLength + _maxPlaintextBytes + _tagLength ||
            (_consumer == null && (_pending.length >= 8 || _pendingBytes + size > 256 * 1024))) {
          _error = const CompanionSecureChannelException();
          _done = true;
          for (final waiter in _waiters) {
            if (!waiter.isCompleted) waiter.completeError(_error!);
          }
          _waiters.clear();
          _pending.clear();
          _pendingBytes = 0;
          _errorConsumer?.call(_error!);
          unawaited(_socket.close(WebSocketStatus.policyViolation));
          return;
        }
        if (_done) return;
        if (_consumer != null) {
          _consumer!(value);
        } else if (_waiters.isNotEmpty) {
          _waiters.removeFirst().complete(value);
        } else {
          _pending.add(value);
          _pendingBytes += size;
        }
      },
      onError: (Object error, StackTrace stack) {
        _error = error;
        _errorStack = stack;
        _errorConsumer?.call(error, stack);
      },
      onDone: () {
        _done = true;
        _doneConsumer?.call();
      },
      cancelOnError: false,
    );
  }

  Future<void> dispose() => _subscription.cancel();

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final List<dynamic> _pending = <dynamic>[];
  int _pendingBytes = 0;
  final Queue<Completer<dynamic>> _waiters = Queue<Completer<dynamic>>();
  void Function(dynamic)? _consumer;
  void Function(Object, [StackTrace?])? _errorConsumer;
  void Function()? _doneConsumer;
  Object? _error;
  StackTrace? _errorStack;
  bool _done = false;

  Future<dynamic> next(Duration timeout) async {
    if (_pending.isNotEmpty) {
      final value = _pending.removeAt(0);
      _pendingBytes -= value is String ? utf8.encode(value).length : (value as List<int>).length;
      return value;
    }
    if (_error != null || _done) throw const CompanionSecureChannelException();
    final waiter = Completer<dynamic>();
    _waiters.add(waiter);
    return waiter.future.timeout(timeout);
  }

  void start(void Function(dynamic) consumer, void Function(Object, [StackTrace?]) onError, void Function() onDone) {
    _consumer = (value) {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete(value);
      } else {
        consumer(value);
      }
    };
    _errorConsumer = onError;
    _doneConsumer = onDone;
    for (final value in _pending) {
      consumer(value);
    }
    _pending.clear();
    _pendingBytes = 0;
    if (_error != null) onError(_error!, _errorStack);
    if (_done) onDone();
  }
}
