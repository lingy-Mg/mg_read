part of mgread_plugin_runtime;

/// Maximum JSON-encoded control request or response supported by both ends.
const _maxControlFrameBytes = 64 * 1024;

/// Per-connection request multiplexer limit negotiated by `runtime.hello`.
const _maxInFlightRequests = 256;

/// Client-side byte window that prevents a large pending batch from growing.
const _maxOutboundQueueBytes = 1024 * 1024;

/// JSON object shape after Dart's decoder has discarded non-string keys.
typedef _RuntimeJsonObject = Map<String, Object?>;

/// Pending control calls indexed by their client-direction correlation id.
typedef _PendingRequestMap = Map<String, _PendingRequest>;

///
/// Runtime-owned client for one already-validated loopback WebSocket session.
///
/// It multiplexes independent request/response pairs, applies both count and
/// byte budgets, correlates replies with a boot and trace identity, and turns
/// all transport failures into stable Facade exceptions. It is not exposed to
/// the Flutter application.
final class _WireConnection {
  _WireConnection._(this._ready, this._socket) {
    _messages = _socket.cast<Object?>().listen(
      _onMessage,
      cancelOnError: false,
      onDone: _failAllPending,
      onError: (_, __) => _failAllPending(),
    );
  }

  /// Ready identity shared by every envelope sent over this connection.
  final _RuntimeReady _ready;

  /// Internal loopback socket; package callers never receive this value.
  final WebSocket _socket;

  /// Typed stream subscription that accepts text only after explicit validation.
  late final StreamSubscription<Object?> _messages;

  /// Outstanding requests and their completers, bounded before socket writes.
  final _PendingRequestMap _pending = <String, _PendingRequest>{};

  /// Adds entropy to client-direction IDs beyond the monotonic local sequence.
  final Random _random = Random.secure();

  /// Terminal transport state; all pending calls fail when it becomes true.
  bool _closed = false;

  /// Sum of encoded request bytes held in [_pending]'s control window.
  int _inFlightControlBytes = 0;

  /// Monotonic per-connection component of a client-direction request ID.
  int _requestSequence = 0;

  /// Opens a compression-disabled WebSocket to the ready Runtime loopback port.
  static Future<_WireConnection> connect(_RuntimeReady ready) async {
    final socket = await WebSocket.connect(
      Uri(
        scheme: 'ws',
        host: ready.host,
        port: ready.port,
        path: '/v1/rpc',
      ).toString(),
      compression: CompressionOptions.compressionOff,
    ).timeout(_controlTimeout);
    return _WireConnection._(ready, socket);
  }

  ///
  /// Negotiates the fixed control-plane limits before a capability call.
  ///
  /// This verifies that the ready record, connected Core, and Flutter package
  /// agree on boot identity, Node/protocol versions, frame limits, concurrency,
  /// byte backpressure, and cancellation semantics.
  Future<void> hello() async {
    final result = await request(
      method: 'runtime.hello',
      params: const <String, Object?>{},
    );
    final hello = _jsonObject(result, 'Runtime hello result');
    if (hello['protocolVersion'] != _protocolVersion ||
        hello['bootId'] != _ready.bootId ||
        hello['nodeVersion'] != _expectedNodeVersion ||
        hello['maxFrameBytes'] != _maxControlFrameBytes ||
        hello['maxInlineBytes'] != _maxControlFrameBytes ||
        hello['maxInFlightRequests'] != _maxInFlightRequests ||
        hello['maxOutboundQueueBytes'] != _maxOutboundQueueBytes ||
        hello['supportsCancellation'] != true) {
      throw const PluginRuntimeException(
        'version_incompatible',
        'The desktop Runtime hello response is incompatible.',
      );
    }
  }

  ///
  /// Sends one multiplexed control request and waits for its correlated result.
  ///
  /// The request gets a unique client-direction ID plus trace ID. A local
  /// timeout emits a best-effort cancellation but remains authoritative even
  /// if the Core replies later. The `finally` block always frees the local
  /// count/byte budget, preventing stale calls from causing false overload.
  Future<Object?> request({
    required String method,
    required Map<String, Object?> params,
    String? idempotencyKey,
  }) async {
    if (_closed) {
      throw const PluginRuntimeException(
        'transport_disconnected',
        'The Runtime transport is disconnected.',
      );
    }
    if (_pending.length >= _maxInFlightRequests) {
      throw const PluginRuntimeException(
        'overloaded',
        'The Runtime control plane has reached its in-flight request limit.',
      );
    }

    final id = _nextId();
    final traceId = 'trace:$id';
    final completer = Completer<Object?>();
    final deadline = DateTime.now().add(_controlTimeout).millisecondsSinceEpoch;
    final encoded = jsonEncode(<String, Object?>{
      'v': _protocolVersion,
      'type': 'request',
      'bootId': _ready.bootId,
      'id': id,
      'method': method,
      'traceId': traceId,
      'deadlineUnixMs': '$deadline',
      'idempotencyKey': idempotencyKey,
      'params': params,
    });
    final encodedBytes = utf8.encode(encoded).length;
    if (encodedBytes > _maxControlFrameBytes) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The Runtime control request exceeds its 64 KiB limit.',
      );
    }
    if (_inFlightControlBytes + encodedBytes > _maxOutboundQueueBytes) {
      throw const PluginRuntimeException(
        'overloaded',
        'The Runtime control request window has reached its byte limit.',
      );
    }

    _pending[id] = _PendingRequest(completer, traceId, encodedBytes);
    _inFlightControlBytes += encodedBytes;
    try {
      _socket.add(encoded);
      return await completer.future.timeout(
        _controlTimeout,
        onTimeout: () {
          _sendCancellation(id, traceId);
          throw const PluginRuntimeException(
            'timeout',
            'The Runtime capability call timed out.',
          );
        },
      );
    } on PluginRuntimeException {
      rethrow;
    } on Object {
      throw const PluginRuntimeException(
        'transport_disconnected',
        'The Runtime transport is disconnected.',
      );
    } finally {
      _removePending(id);
    }
  }

  /// Stops receiving replies, fails pending calls, then attempts a clean close.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _failAllPending();
    await _messages.cancel();
    try {
      await _socket
          .close(WebSocketStatus.goingAway, 'Runtime is stopping.')
          .timeout(_controlTimeout);
    } on Object {
      // Process-tree cleanup remains the owning supervisor's responsibility.
    }
  }

  /// Fails all calls immediately after the child monitor observes process exit.
  void markProcessExited() {
    if (!_closed) {
      _closed = true;
      _failAllPending();
    }
  }

  /// Builds an opaque client-direction ID safe to correlate only in this session.
  String _nextId() {
    _requestSequence += 1;
    return 'c:dart-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${_requestSequence.toRadixString(36)}-'
        '${_random.nextInt(1 << 32).toRadixString(36)}';
  }

  /// Sends a best-effort, response-free cancellation for a timed-out request.
  void _sendCancellation(String targetId, String traceId) {
    if (_closed) {
      return;
    }
    final id = _nextId();
    try {
      _socket.add(
        jsonEncode(<String, Object?>{
          'v': _protocolVersion,
          'type': 'cancel',
          'bootId': _ready.bootId,
          'id': id,
          'targetId': targetId,
          'traceId': traceId,
        }),
      );
    } on Object {
      // Cancellation is best effort. The deadline remains authoritative.
    }
  }

  ///
  /// Validates one inbound WebSocket event before completing any pending call.
  ///
  /// A non-text message, malformed envelope, boot mismatch, missing ID, or
  /// trace mismatch invalidates the session because it could mis-correlate
  /// independent concurrent calls. A late reply for an already timed-out ID is
  /// intentionally ignored because its local cancellation race is expected.
  void _onMessage(Object? message) {
    if (message is! String) {
      _failAllPending();
      return;
    }

    try {
      final envelope = _jsonObject(
        jsonDecode(message),
        'Runtime wire response',
      );
      if (envelope['v'] != _protocolVersion ||
          envelope['bootId'] != _ready.bootId) {
        _failAllPending();
        return;
      }
      final id = envelope['id'];
      if (id is! String) {
        _failAllPending();
        return;
      }
      final pending = _pending[id];
      if (pending == null) {
        // A response can legitimately arrive after a local timeout emitted a
        // best-effort cancellation. It must not disconnect unrelated calls.
        return;
      }
      if (envelope['traceId'] != pending.traceId) {
        _failAllPending();
        return;
      }

      switch (envelope['type']) {
        case 'response':
          pending.completer.complete(envelope['result']);
          return;
        case 'error':
          final error = _jsonObject(
            envelope['error'],
            'Runtime error response',
          );
          final code = error['code'];
          final text = error['message'];
          pending.completer.completeError(
            PluginRuntimeException(
              code is String ? code : 'internal',
              text is String ? text : 'The Runtime returned an invalid error.',
            ),
          );
          return;
        default:
          _failAllPending();
          return;
      }
    } on Object {
      _failAllPending();
    }
  }

  /// Marks this connection terminal and completes every unresolved call once.
  void _failAllPending() {
    if (_closed && _pending.isEmpty) {
      return;
    }
    _closed = true;
    const error = PluginRuntimeException(
      'transport_disconnected',
      'The Runtime transport is disconnected.',
    );
    final pending = List<_PendingRequest>.of(_pending.values);
    _pending.clear();
    _inFlightControlBytes = 0;
    for (final request in pending) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
  }

  /// Removes one completed/timed-out request and returns its byte budget.
  void _removePending(String id) {
    final pending = _pending.remove(id);
    if (pending != null) {
      _inFlightControlBytes -= pending.encodedBytes;
    }
  }
}

/// Local correlation and budget accounting for one in-flight control request.
final class _PendingRequest {
  const _PendingRequest(this.completer, this.traceId, this.encodedBytes);

  /// Completes with the decoded JSON value or a stable Runtime exception.
  final Completer<Object?> completer;

  /// UTF-8 byte count consumed from the client's bounded control window.
  final int encodedBytes;

  /// Must match the server response before this completer can be resolved.
  final String traceId;
}

///
/// Narrows a decoded JSON value to an object with string keys.
///
/// JSON itself permits only string object keys, but `dart:convert` exposes the
/// wider map type. Copying here establishes the internal typed boundary and
/// rejects scalar/array responses before a capability decoder can use them.
_RuntimeJsonObject _jsonObject(Object? value, String context) {
  if (value is Map<Object?, Object?>) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        if (entry.key case final String key) key: entry.value,
    };
  }
  throw PluginRuntimeException(
    'invalid_response',
    '$context must be a JSON object.',
  );
}
