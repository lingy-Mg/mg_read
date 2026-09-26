part of mgread_plugin_runtime;

/// Management stays on the shared worker. Content calls go directly to each
/// initialized plugin, with one HTTP connection per call. Closing that connection
/// cancels its async work; no call IDs or separate cancellation requests cross
/// the transport. A worker boundary invalidates all registered endpoints.
extension _NativeRuntimeSupervisorTransport on _NativeRuntimeSupervisor {
  Future<_NativePluginEndpoint> _initializePlugin(
    _NativeRuntimeReady ready,
    String id,
  ) {
    return _pluginInitializations.putIfAbsent(id, () async {
      try {
        final raw = await _invokeReadyRpc(
          ready,
          method: 'plugins.native.initialize.v1',
          params: {'pluginId': id},
          timeout: _NativeRuntimeSupervisor._startupTimeout,
        );
        return _resourceEndpoints.register(raw, id);
      } on Object catch (error) {
        if (error is PluginRuntimeException &&
            error.code == 'plugin_init_failed')
          await _breakWorker(error);
        _pluginInitializations.remove(id);
        rethrow;
      }
    });
  }

  Future<Object?> _invokeRpc({
    required String method,
    required Map<String, Object?> params,
    Duration timeout = const Duration(seconds: 5),
    PluginInvocationCancellation? cancellation,
  }) async {
    cancellation?._throwIfCancelled();
    final ready = await _ensureStarted();
    if (method.startsWith('source.') ||
        method.startsWith('runtime.sourceResource.')) {
      final route = method.startsWith('runtime.sourceResource.')
          ? _SourceResourceUrl.require(params['url'] as String)
          : null;
      final id = route?.pluginId ?? params['pluginId'] as String;
      if (route != null && route.engine != PluginEngine.native)
        throw const PluginRuntimeException(
          'invalid_request',
          'Resource engine does not match its plugin.',
        );
      final endpoint = await _awaitPluginInvocation(
        _initializePlugin(ready, id),
        cancellation,
      );
      cancellation?._throwIfCancelled();
      if (route != null) {
        return method == 'runtime.sourceResource.resolve.v1'
            ? {
                'url': route.uri
                    .replace(host: '127.0.0.1', port: endpoint.port)
                    .toString(),
              }
            : {'pluginId': id, 'request': route.request};
      }
      return _invokeReadyRpc(
        ready,
        method: method,
        params: params,
        timeout: timeout,
        cancellation: cancellation,
        endpoint: endpoint,
      );
    }
    return _invokeReadyRpc(
      ready,
      method: method,
      params: params,
      timeout: timeout,
      cancellation: cancellation,
    );
  }

  Future<Object?> _invokeReadyRpc(
    _NativeRuntimeReady ready, {
    required String method,
    required Map<String, Object?> params,
    Duration timeout = const Duration(seconds: 5),
    PluginInvocationCancellation? cancellation,
    _NativePluginEndpoint? endpoint,
  }) async {
    cancellation?._throwIfCancelled();
    if (!identical(ready, _ready))
      throw const PluginRuntimeException(
        'transport_disconnected',
        'The native worker is unavailable.',
      );
    // A dedicated connection lets abort cancel exactly this request, including
    // after headers arrive. Native HTTP never passes through the system proxy.
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    final id = 'local-${++_invocationSequence}';
    final pending = _NativeInFlight();
    _inFlight[id] = pending;
    void abort() {
      pending.request?.abort();
      client.close(force: true);
    }

    try {
      return await _awaitPluginInvocation<Object?>(
        Future.any<Object?>([
          _postRpc(
            client: client,
            ready: ready,
            method: method,
            params: params,
            pending: pending,
            endpoint: endpoint,
          ),
          pending.failure.future.then<Object?>((error) => throw error),
        ]),
        cancellation,
        onCancel: abort,
      ).timeout(
        timeout,
        onTimeout: () {
          abort();
          throw const PluginRuntimeException(
            'timeout',
            'The native HTTP request timed out.',
          );
        },
      );
    } on PluginRuntimeException catch (error) {
      cancellation?._throwIfCancelled();
      if (error.code == 'transport_disconnected' ||
          (endpoint == null && error.code == 'timeout'))
        await _breakWorker(error);
      rethrow;
    } on Object {
      cancellation?._throwIfCancelled();
      const failure = PluginRuntimeException(
        'transport_disconnected',
        'The native HTTP request failed.',
      );
      await _breakWorker(failure);
      throw failure;
    } finally {
      _inFlight.remove(id);
      abort();
    }
  }

  Future<Object?> _postRpc({
    required HttpClient client,
    required _NativeRuntimeReady ready,
    required String method,
    required Map<String, Object?> params,
    required _NativeInFlight pending,
    _NativePluginEndpoint? endpoint,
  }) async {
    final request = await client.postUrl(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: endpoint?.port ?? ready.port,
        path: endpoint == null ? '/rpc' : '/invoke',
      ),
    );
    pending.request = request;
    request.persistentConnection = false;
    request.headers
      ..set(
        HttpHeaders.authorizationHeader,
        'Bearer ${endpoint?.controlToken ?? ready.token}',
      )
      ..contentType = ContentType.json;
    request.write(jsonEncode({'method': method, 'params': params}));
    final response = await request.close();
    final body = await _readNativeResponse(response);
    final envelope = _nativeObject(jsonDecode(body), 'Native HTTP response');
    if (!identical(ready, _ready))
      throw const PluginRuntimeException(
        'transport_disconnected',
        'Native worker generation has changed.',
      );
    if (envelope['ok'] == true && envelope.containsKey('result')) {
      if (endpoint != null) {
        final result = _nativeObject(
          envelope['result'],
          'Native source result',
        );
        if (result['pluginId'] != params['pluginId'])
          throw const PluginRuntimeException(
            'invalid_response',
            'Source result owner mismatch.',
          );
        _resourceEndpoints.validateResult(
          result,
          params['pluginId'] as String?,
        );
      }
      return envelope['result'];
    }
    if (envelope['ok'] == false) {
      final error = _nativeObject(envelope['error'], 'Native HTTP error');
      final code = error['code'], message = error['message'];
      if (code is String &&
          RegExp(r'^[a-z0-9_]{1,64}$').hasMatch(code) &&
          message is String &&
          message.isNotEmpty &&
          message.length <= _maxStructuredDiagnosticMessageLength)
        throw PluginRuntimeException(code, message);
    }
    throw const PluginRuntimeException(
      'invalid_response',
      'Invalid native HTTP response.',
    );
  }

  Future<String> _readNativeResponse(HttpClientResponse response) async {
    if (response.contentLength >
        _NativeRuntimeSupervisor._maxControlResponseBytes)
      throw const PluginRuntimeException(
        'response_too_large',
        'Native response exceeds its size limit.',
      );
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length >
          _NativeRuntimeSupervisor._maxControlResponseBytes)
        throw const PluginRuntimeException(
          'response_too_large',
          'Native response exceeds its size limit.',
        );
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
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
    _stopUnconfirmed = false;
    _ready = null;
    _resourceEndpoints.clear();
    _pluginInitializations.clear();
    _startup = null;
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
    final process = _process;
    final job = _jobObject;
    _ready = null;
    _resourceEndpoints.clear();
    _pluginInitializations.clear();
    _startup = null;
    if (failure != null) {
      for (final pending in _inFlight.values) {
        if (!pending.failure.isCompleted) {
          pending.failure.completeError(failure);
        }
        pending.request?.abort();
      }
    }
    _intentionalStop = true;
    _stopUnconfirmed = true;
    try {
      if (_isAndroid) {
        await _NativeRuntimeSupervisor._channel
            .invokeMethod<void>('stop')
            .timeout(_NativeRuntimeSupervisor._shutdownTimeout);
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
        await process.exitCode.timeout(
          _NativeRuntimeSupervisor._shutdownTimeout,
        );
      }
      _process = null;
      _stopUnconfirmed = false;
    } on Object {
      throw const PluginRuntimeException(
        'native_stop_unconfirmed',
        'The native worker did not confirm exit; restart was stopped.',
      );
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
    if (_ready != null) {
      try {
        await _invokeRpc(
          method: 'runtime.native.shutdown.v1',
          params: const <String, Object?>{},
          timeout: _NativeRuntimeSupervisor._shutdownTimeout,
        );
      } on Object {
        // A failed HTTP shutdown still requires confirmed process termination.
      }
    }
    await _stopWorker();
    await _ensureStarted();
  }
}
