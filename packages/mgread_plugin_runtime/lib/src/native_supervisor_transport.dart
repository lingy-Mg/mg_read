part of mgread_plugin_runtime;

/// Owns native host HTTP requests, cancellation, and worker teardown.
///
/// Kept separate from the Facade coordinator so each source file stays
/// small enough to review and validate independently.
extension _NativeRuntimeSupervisorTransport on _NativeRuntimeSupervisor {
  void _initializeHttpClient() {
    final client = HttpClient()
      ..connectionTimeout = _startupTimeout
      ..maxConnectionsPerHost = 16
      ..findProxy = (_) => 'DIRECT';
    _httpClient = client;
  }

  Future<Object?> _invokeRpc({
    required String method,
    required Map<String, Object?> params,
    Duration timeout = const Duration(seconds: 5),
    PluginInvocationCancellation? cancellation,
  }) async {
    final ready = await _ensureStarted();
    return _invokeReadyRpc(
      ready,
      method: method,
      params: params,
      timeout: timeout,
      cancellation: cancellation,
    );
  }

  /// Sends a call after readiness without awaiting the memoized startup future.
  /// Startup uses this to restore a saved proxy before admitting app calls.
  Future<Object?> _invokeReadyRpc(
    _NativeRuntimeReady ready, {
    required String method,
    required Map<String, Object?> params,
    Duration timeout = const Duration(seconds: 5),
    PluginInvocationCancellation? cancellation,
  }) async {
    cancellation?._throwIfCancelled();
    final client = _httpClient;
    if (client == null || !identical(ready, _ready)) {
      throw const PluginRuntimeException(
        'transport_disconnected',
        'The native Runtime control connection is unavailable.',
      );
    }
    final id =
        'dart-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
        '${++_invocationSequence}';
    final pending = _NativeInFlight();
    _inFlight[id] = pending;
    final operation = _postRpc(
      client: client,
      ready: ready,
      id: id,
      method: method,
      params: params,
      pending: pending,
    );
    try {
      return await _awaitPluginInvocation<Object?>(
        Future.any<Object?>(<Future<Object?>>[
          operation,
          pending.failure.future.then<Object?>((error) => throw error),
        ]),
        cancellation,
        onCancel: () => unawaited(_cancelInvocation(id, ready, pending)),
      ).timeout(
        timeout,
        onTimeout: () {
          unawaited(
            _breakWorker(
              const PluginRuntimeException(
                'timeout',
                'The native Runtime capability call timed out; the worker was stopped.',
              ),
            ),
          );
          throw const PluginRuntimeException(
            'timeout',
            'The native Runtime capability call timed out; the worker was stopped.',
          );
        },
      );
    } on PluginRuntimeException catch (error) {
      if (error.code == 'transport_disconnected' || error.code == 'timeout') {
        await _breakWorker(error);
      }
      rethrow;
    } on TimeoutException {
      final failure = const PluginRuntimeException(
        'timeout',
        'The native Runtime capability call timed out; the worker was stopped.',
      );
      await _breakWorker(failure);
      throw failure;
    } on Object {
      const failure = PluginRuntimeException(
        'transport_disconnected',
        'The native Runtime control request failed.',
      );
      await _breakWorker(failure);
      throw PluginRuntimeException(
        failure.code,
        failure.message,
        diagnostics: latestDiagnostics,
      );
    } finally {
      _inFlight.remove(id);
    }
  }

  Future<Object?> _postRpc({
    required HttpClient client,
    required _NativeRuntimeReady ready,
    required String id,
    required String method,
    required Map<String, Object?> params,
    required _NativeInFlight pending,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: ready.port,
      path: '/rpc',
    );
    final request = await client.postUrl(uri);
    pending.request = request;
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${ready.token}')
      ..contentType = ContentType.json;
    request.write(
      jsonEncode(<String, Object?>{
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    final response = await request.close();
    final body = await _readNativeResponse(response);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const PluginRuntimeException(
        'invalid_response',
        'The native Runtime returned invalid JSON.',
      );
    }
    final envelope = _nativeObject(decoded, 'Native Runtime response');
    if (envelope['ok'] == true && envelope.containsKey('result')) {
      return envelope['result'];
    }
    if (envelope['ok'] == false) {
      final error = _nativeObject(envelope['error'], 'Native Runtime error');
      final code = error['code'];
      final message = error['message'];
      if (code is String &&
          RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(code) &&
          message is String &&
          message.isNotEmpty &&
          message.length <= _maxStructuredDiagnosticMessageLength) {
        throw PluginRuntimeException(code, message);
      }
    }
    throw const PluginRuntimeException(
      'invalid_response',
      'The native Runtime returned an invalid response envelope.',
    );
  }

  Future<String> _readNativeResponse(HttpClientResponse response) async {
    if (response.contentLength >
        _NativeRuntimeSupervisor._maxControlResponseBytes) {
      throw const PluginRuntimeException(
        'response_too_large',
        'The native Runtime response exceeded its allowed size.',
      );
    }
    final bytes = <int>[];
    try {
      await for (final chunk in response) {
        if (bytes.length + chunk.length >
            _NativeRuntimeSupervisor._maxControlResponseBytes) {
          throw const PluginRuntimeException(
            'response_too_large',
            'The native Runtime response exceeded its allowed size.',
          );
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    } on PluginRuntimeException {
      rethrow;
    } on Object {
      throw const PluginRuntimeException(
        'transport_disconnected',
        'The native Runtime response could not be read.',
      );
    }
  }

  Future<void> _cancelInvocation(
    String id,
    _NativeRuntimeReady ready,
    _NativeInFlight pending,
  ) async {
    const stopped = PluginRuntimeException(
      'cancelled_worker_stopped',
      'The native Runtime worker was stopped because cancellation did not settle.',
    );
    final client = _httpClient;
    if (client == null) {
      pending.request?.abort();
      if (identical(ready, _ready)) await _breakWorker(stopped);
      return;
    }
    var settled = false;
    try {
      final request = await client.postUrl(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: ready.port,
          path: '/cancel',
        ),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${ready.token}')
        ..contentType = ContentType.json;
      request.write(jsonEncode(<String, Object?>{'id': id}));
      final response = await request.close().timeout(
        _NativeRuntimeSupervisor._shutdownTimeout,
      );
      final body = await _readNativeResponse(
        response,
      ).timeout(_NativeRuntimeSupervisor._shutdownTimeout);
      final result = _nativeObject(
        jsonDecode(body),
        'Native cancellation result',
      );
      settled = result['ok'] == true && result['settled'] == true;
    } on Object {
      // An unconfirmed cancellation cannot leave a possibly busy native job
      // attached to a worker that may accept another capability call.
    } finally {
      pending.request?.abort();
    }
    if (!settled && identical(ready, _ready)) await _breakWorker(stopped);
  }

  Future<void> _onProcessExit(
    Process process,
    int exitCode,
    Completer<String> readyLine,
  ) async {
    if (!readyLine.isCompleted) {
      readyLine.completeError(
        const PluginRuntimeException(
          'runtime_exited_before_ready',
          'The native Runtime host exited before it became ready.',
        ),
      );
    }
    if (!identical(_process, process)) return;
    _process = null;
    _ready = null;
    _startup = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    _closeJobObject();
    if (!_disposed && !_intentionalStop) {
      const failure = PluginRuntimeException(
        'runtime_process_exited',
        'The native Runtime host exited unexpectedly.',
      );
      _record(
        const RuntimeDiagnostic(
          code: 'runtime_process_exited',
          level: RuntimeDiagnosticLevel.fatal,
          message: 'The native Runtime host exited unexpectedly.',
        ),
      );
      for (final pending in _inFlight.values) {
        if (!pending.failure.isCompleted)
          pending.failure.completeError(failure);
      }
    }
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  Future<void> _breakWorker(PluginRuntimeException failure) {
    final current = _cleanup;
    if (current != null) return current;
    late final Future<void> task;
    task = _stopWorker(failure: failure).whenComplete(() {
      if (identical(_cleanup, task)) _cleanup = null;
    });
    _cleanup = task;
    return task;
  }

  Future<void> _stopWorker({PluginRuntimeException? failure}) async {
    final client = _httpClient;
    final process = _process;
    final job = _jobObject;
    _httpClient = null;
    _process = null;
    _ready = null;
    _startup = null;
    client?.close(force: true);
    if (failure != null) {
      for (final pending in _inFlight.values) {
        if (!pending.failure.isCompleted) {
          pending.failure.completeError(failure);
        }
        pending.request?.abort();
      }
    }
    _intentionalStop = true;
    try {
      if (_isAndroid) {
        try {
          await _NativeRuntimeSupervisor._channel
              .invokeMethod<void>('stop')
              .timeout(_NativeRuntimeSupervisor._shutdownTimeout);
        } on Object {
          // The Android service stop is best effort after its private process
          // has already failed or been asked to shut down.
        }
      }
      if (job != null) {
        try {
          job.close();
        } on WindowsJobObjectException catch (error) {
          _record(
            RuntimeDiagnostic(
              code: error.code,
              level: RuntimeDiagnosticLevel.error,
              message: error.message,
            ),
          );
          process?.kill();
        }
      } else {
        process?.kill();
      }
      if (process != null) {
        try {
          await process.exitCode.timeout(
            _NativeRuntimeSupervisor._shutdownTimeout,
          );
        } on TimeoutException {
          process.kill();
        } on Object {
          // The process has already exited.
        }
      }
    } finally {
      _jobObject = null;
      _intentionalStop = false;
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _stdoutSubscription = null;
      _stderrSubscription = null;
    }
  }

  Future<void> _restartAfterManagementChange() async {
    await _stopWorker();
    await _ensureStarted();
  }
}
