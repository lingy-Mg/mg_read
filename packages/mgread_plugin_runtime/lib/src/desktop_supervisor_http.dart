part of mgread_plugin_runtime;

/// Owns the bounded loopback HTTP phase of desktop Runtime startup.
///
/// The probe deliberately uses one deadline across connection, headers, and
/// body reads. Each attempt owns a separate client so a stalled response can
/// be force-closed without leaving a retry's socket in the pool.
extension _DesktopRuntimeSupervisorHttp on _DesktopRuntimeSupervisor {
  /// Confirms that stdout-ready, HTTP, and version identity belong to one
  /// Runtime Core before the WebSocket is trusted.
  ///
  /// Connection refusal is retried briefly for the child-internal race between
  /// writing stdout and accepting loopback HTTP. Once a request is connected,
  /// a stalled header/body is terminal for this startup attempt.
  Future<void> _probeHttpReady(
    _RuntimeReady ready, {
    required DateTime deadline,
  }) async {
    final uri = Uri(
      scheme: 'http',
      host: ready.host,
      port: ready.port,
      path: '/health/ready',
    );
    while (true) {
      final remaining = _startupRemaining(deadline);
      if (remaining == null) break;

      final client = HttpClient();
      HttpClientRequest? request;
      var responseStarted = false;
      var connectedAttempt = false;
      try {
        request = await client.getUrl(uri).timeout(remaining);
        connectedAttempt = true;
        final response = await request.close().timeout(
          _startupRemaining(deadline) ?? Duration.zero,
        );
        responseStarted = true;
        final body = await _readHttpResponseBody(
          response,
          _startupRemaining(deadline) ?? Duration.zero,
        );
        if (response.statusCode == HttpStatus.ok) {
          final decoded = _jsonObject(
            jsonDecode(body),
            'Runtime health response',
          );
          if (decoded['status'] == 'ready' &&
              decoded['bootId'] == ready.bootId &&
              decoded['nodeVersion'] == ready.nodeVersion &&
              decoded['protocolVersion'] == _protocolVersion) {
            return;
          }
        }
      } on TimeoutException {
        // A connected request that cannot produce headers/body must not be
        // retried while its socket remains open.
        if (connectedAttempt || responseStarted) break;
      } on Object {
        // Connection refusal is the only expected retryable startup race.
      } finally {
        try {
          request?.abort();
        } on Object {
          // The force-closed client remains the authoritative cleanup path.
        }
        client.close(force: true);
      }

      final retryDelay = _startupRemaining(deadline);
      if (retryDelay == null) break;
      await Future<void>.delayed(
        retryDelay < const Duration(milliseconds: 25)
            ? retryDelay
            : const Duration(milliseconds: 25),
      );
    }

    _recordDiagnostic(
      const RuntimeDiagnostic(
        code: 'runtime_http_readiness_failed',
        level: RuntimeDiagnosticLevel.error,
        message: 'The desktop Runtime did not pass its HTTP readiness check.',
      ),
    );
    throw _failure(
      'runtime_not_ready',
      'The desktop Runtime did not pass its readiness check.',
    );
  }

  /// Reads the response while retaining a subscription that can be cancelled
  /// when the shared startup deadline expires.
  Future<String> _readHttpResponseBody(
    HttpClientResponse response,
    Duration timeout,
  ) async {
    final bytes = <int>[];
    final completed = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    try {
      subscription = response.listen(
        bytes.addAll,
        onError: (Object error, StackTrace stackTrace) {
          if (!completed.isCompleted) {
            completed.completeError(error, stackTrace);
          }
        },
        onDone: () {
          if (!completed.isCompleted) completed.complete();
        },
        cancelOnError: true,
      );
      await completed.future.timeout(timeout);
      return utf8.decode(bytes);
    } finally {
      await subscription?.cancel();
    }
  }
}

/// Returns the remaining shared startup budget, or null once it is exhausted.
Duration? _startupRemaining(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining <= Duration.zero ? null : remaining;
}
