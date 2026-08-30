part of mgread_plugin_runtime;

/// Maximum JSON-encoded control request or response supported by both ends.
const _maxControlFrameBytes = 4 * 1024 * 1024;

/// Per-connection request multiplexer limit negotiated by `runtime.hello`.
const _maxInFlightRequests = 256;

/// Client-side byte window that prevents a large pending batch from growing.
const _maxOutboundQueueBytes = 8 * 1024 * 1024;

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
  _WireConnection._(this._ready, this._socket, this._browserSessionHost) {
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
  final WindowsBrowserSessionHost? _browserSessionHost;
  final Set<String> _hostJobs = <String>{};

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
  static Future<_WireConnection> connect(
    _RuntimeReady ready, {
    required Directory dataRoot,
    Uri? proxyUri,
  }) async {
    final client = proxyUri == null
        ? null
        : (HttpClient()
            ..findProxy = (_) => 'PROXY ${proxyUri.host}:${proxyUri.port}');
    final socket = await WebSocket.connect(
      Uri(
        scheme: 'ws',
        host: ready.host,
        port: ready.port,
        path: '/v1/rpc',
      ).toString(),
      compression: CompressionOptions.compressionOff,
      customClient: client,
    ).timeout(_controlTimeout);
    return _WireConnection._(
      ready,
      socket,
      Platform.isWindows ? WindowsBrowserSessionHost(dataRoot) : null,
    );
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
    Duration timeout = _controlTimeout,
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
    final deadline = DateTime.now().add(timeout).millisecondsSinceEpoch;
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
        'The Runtime control request exceeds its negotiated limit.',
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
        timeout,
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

  /// Reads a Runtime-owned binary resource through the private loopback data
  /// plane. This helper is intentionally unreachable from the public Facade.
  Future<Stream<List<int>>> readTransferResource({
    required String token,
    required int expectedBytes,
  }) async {
    if (_closed ||
        token.isEmpty ||
        expectedBytes <= 0 ||
        expectedBytes > maxPluginTransferBytes) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The Runtime transfer resource request is invalid.',
      );
    }
    final client = HttpClient()..connectionTimeout = _controlTimeout;
    final request = await client.getUrl(
      Uri(
        scheme: 'http',
        host: _ready.host,
        port: _ready.port,
        path: '/v2/plugin-artifact/$token',
      ),
    );
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(_controlTimeout);
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength != expectedBytes) {
      client.close(force: true);
      throw const PluginRuntimeException(
        'plugin_transfer_size_mismatch',
        'The Runtime returned an invalid transfer resource.',
      );
    }
    var received = 0;
    return response.transform<List<int>>(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          received += chunk.length;
          if (received > expectedBytes) {
            sink.addError(
              const PluginRuntimeException(
                'plugin_transfer_size_mismatch',
                'The Runtime transfer resource exceeded its declared size.',
              ),
            );
            client.close(force: true);
            return;
          }
          sink.add(chunk);
        },
        handleDone: (sink) {
          client.close();
          if (received != expectedBytes) {
            sink.addError(
              const PluginRuntimeException(
                'plugin_transfer_size_mismatch',
                'The Runtime transfer resource was truncated.',
              ),
            );
          }
          sink.close();
        },
      ),
    );
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
      if (envelope['type'] == 'host_request') {
        unawaited(_handleHostRequest(envelope));
        return;
      }
      if (envelope['type'] == 'host_cancel') {
        _handleHostCancel(envelope);
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

  Future<void> _handleHostRequest(_RuntimeJsonObject envelope) async {
    final id = envelope['id'];
    final traceId = envelope['traceId'];
    final deadlineRaw = envelope['deadlineUnixMs'];
    final params = envelope['params'];
    if (id is! String ||
        !id.startsWith('s:') ||
        traceId is! String ||
        traceId.isEmpty ||
        envelope['method'] != 'host.browserSession.v1' ||
        deadlineRaw is! String ||
        params is! Map<Object?, Object?> ||
        _hostJobs.contains(id)) {
      _failAllPending();
      return;
    }
    final deadline = int.tryParse(deadlineRaw);
    if (deadline == null) {
      _failAllPending();
      return;
    }
    final host = _browserSessionHost;
    if (host == null) {
      _sendHostError(id, traceId, 'unsupported');
      return;
    }
    _hostJobs.add(id);
    try {
      if (deadline <= DateTime.now().millisecondsSinceEpoch) {
        throw const WindowsBrowserSessionException('timeout');
      }
      final result = await host.request(
        jobId: id,
        deadlineUnixMs: deadline,
        raw: <String, Object?>{
          for (final entry in params.entries)
            if (entry.key is String) entry.key! as String: entry.value,
        },
      );
      if (_hostJobs.remove(id)) _sendHostResult(id, traceId, result);
    } on WindowsBrowserSessionException catch (error) {
      if (_hostJobs.remove(id)) _sendHostError(id, traceId, error.code);
    } on Object {
      if (_hostJobs.remove(id))
        _sendHostError(id, traceId, 'plugin_execution_failed');
    }
  }

  void _handleHostCancel(_RuntimeJsonObject envelope) {
    final targetId = envelope['targetId'];
    if (targetId is! String || !targetId.startsWith('s:')) {
      _failAllPending();
      return;
    }
    if (_hostJobs.remove(targetId))
      unawaited(_browserSessionHost?.cancel(targetId));
  }

  void _sendHostResult(String id, String traceId, Map<String, Object?> result) {
    _sendHostEnvelope(<String, Object?>{
      'v': _protocolVersion,
      'type': 'host_response',
      'bootId': _ready.bootId,
      'id': id,
      'traceId': traceId,
      'result': result,
    });
  }

  void _sendHostError(String id, String traceId, String code) {
    const allowed = <String>{
      'cancelled',
      'interaction_required',
      'overloaded',
      'plugin_execution_failed',
      'timeout',
      'unsupported',
    };
    _sendHostEnvelope(<String, Object?>{
      'v': _protocolVersion,
      'type': 'host_error',
      'bootId': _ready.bootId,
      'id': id,
      'traceId': traceId,
      'error': <String, Object?>{
        'code': allowed.contains(code) ? code : 'plugin_execution_failed',
      },
    });
  }

  void _sendHostEnvelope(Map<String, Object?> envelope) {
    if (_closed) return;
    final encoded = jsonEncode(envelope);
    if (utf8.encode(encoded).length > _maxControlFrameBytes) {
      _failAllPending();
      return;
    }
    _socket.add(encoded);
  }

  /// Marks this connection terminal and completes every unresolved call once.
  void _failAllPending() {
    if (_closed && _pending.isEmpty) {
      return;
    }
    _closed = true;
    final hostJobs = _hostJobs.toList(growable: false);
    _hostJobs.clear();
    for (final id in hostJobs) {
      unawaited(_browserSessionHost?.cancel(id));
    }
    unawaited(_browserSessionHost?.dispose());
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
