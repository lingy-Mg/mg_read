/// Phone connection and request ownership. Reconnect pulls authoritative state;
/// it never resends mutations, navigation holds or text submissions.
part of 'companion_controller.dart';

extension CompanionClient on CompanionController {
  void cancelSearch() {
    unawaited(_client?.send({'kind': 'cancelSearch'}));
  }

  Future<void> releaseControl() async {
    if (!hasControl) return;
    try {
      await command(CompanionCommandType.releaseControl, ensureControl: false);
    } on Object {
      /* Connection close also releases the lease. */
    }
  }

  Future<CompanionInteraction> beginInteraction() async {
    final before = remoteState;
    final target = _selectedId;
    final channel = _client;
    if (before == null || target == null || channel == null || stale) throw const CompanionFailure('state_unavailable');
    if (!hasControl) {
      final result = await command(CompanionCommandType.acquireControl, ensureControl: false);
      if (result.phase != CompanionCommandPhase.applied) throw CompanionFailure(result.code ?? 'control_required');
      await _refreshState();
    }
    final current = remoteState;
    if (!identical(channel, _client) ||
        _selectedId != target ||
        current == null ||
        !hasControl ||
        current.hostEpoch != before.hostEpoch ||
        current.playbackGeneration != before.playbackGeneration) {
      throw const CompanionFailure('interaction_changed');
    }
    return CompanionInteraction(target, current.hostEpoch, current.controlGeneration, current.playbackGeneration);
  }

  Future<CompanionReceipt> interactionCommand(
    CompanionInteraction interaction,
    CompanionCommandType type, {
    Map<String, Object?> arguments = const {},
  }) async {
    final current = remoteState;
    if (!hasControl ||
        _selectedId != interaction.deviceId ||
        current?.hostEpoch != interaction.hostEpoch ||
        current?.controlGeneration != interaction.controlGeneration ||
        current?.playbackGeneration != interaction.playbackGeneration) {
      throw const CompanionFailure('interaction_changed');
    }
    return command(type, arguments: arguments, ensureControl: false);
  }

  Future<void> connect(CompanionEndpoint endpoint, {bool automatic = false}) async {
    final generation = ++_connectionGeneration;
    await _prepareClientConnect(generation, automatic: automatic);
    if (_disposed || generation != _connectionGeneration) return;
    await _connectEndpoint(endpoint, generation, automatic: automatic);
  }

  Future<void> _prepareClientConnect(int generation, {required bool automatic}) async {
    await initialize();
    if (_disposed || generation != _connectionGeneration) return;
    if (!automatic && !await _network.ensurePermission()) throw const CompanionFailure('local_network_permission_required');
    if (_disposed || generation != _connectionGeneration) return;
    if (!await _network.available()) throw const CompanionFailure('local_network_unavailable');
  }

  Future<void> _connectEndpoint(CompanionEndpoint endpoint, int generation, {required bool automatic}) async {
    if (_disposed || generation != _connectionGeneration) return;
    await _detachClient(generation, rememberSelection: true);
    if (_disposed || generation != _connectionGeneration) return;
    _selectedId = endpoint.deviceId;
    endpoints[endpoint.deviceId] = endpoint;
    await _repository.setSelectedDevice(endpoint.deviceId);
    if (_disposed || generation != _connectionGeneration) return;
    _knownLabels[endpoint.deviceId] = endpoint.label;
    connectionStatus = automatic ? CompanionConnectionStatus.reconnecting : CompanionConnectionStatus.connecting;
    errorCode = null;
    _notify();
    try {
      final channel = await ref.read(companionChannelConnectorProvider)(
        uri: endpoint.uri,
        localDeviceId: identity!.deviceId,
        remoteDeviceId: endpoint.deviceId,
        sharedSecret: const <int>[],
      );
      if (_disposed || _selectedId != endpoint.deviceId || generation != _connectionGeneration) {
        await channel.close();
        return;
      }
      _client = channel;

      _lastClientTick = _clock.elapsedMilliseconds;
      _clientEpoch = null;
      remoteState = null;
      remoteStateAt = null;
      _remoteStateTick = null;
      final stateReady = Completer<void>();
      _authoritativeStateReady = stateReady;
      _clientSubscription = channel.messages.listen(
        (message) {
          if (identical(_client, channel)) unawaited(_receiveClient(message, channel));
        },
        onError: (Object _) {
          if (identical(_client, channel)) unawaited(_lostConnection('connection_lost'));
        },
        onDone: () {
          if (identical(_client, channel)) unawaited(_lostConnection('connection_lost'));
        },
      );
      await stateReady.future.timeout(const Duration(seconds: 5));
      if (_disposed || generation != _connectionGeneration || !identical(_client, channel)) {
        await channel.close();
        return;
      }
      connectionStatus = CompanionConnectionStatus.connected;
      _reconnectAttempts = 0;
      _notify();
    } on Object {
      if (generation != _connectionGeneration || _disposed) return;
      errorCode = 'connection_or_authorization_failed';
      connectionStatus = CompanionConnectionStatus.unauthorized;
      _notify();
      await _detachClient(generation, rememberSelection: true);
      if (automatic) _scheduleReconnect();
      rethrow;
    }
  }

  Future<void> connectManual({required String address, required int port, String? deviceId}) async {
    if (!isLanSyncPrivateIpv4(address) || port < 1 || port > 65535) throw const CompanionFailure('invalid_lan_endpoint');
    final generation = ++_connectionGeneration;
    await _prepareClientConnect(generation, automatic: false);
    if (_disposed || generation != _connectionGeneration) return;
    var resolvedId = deviceId;
    var label = _knownLabels[deviceId] ?? 'TV';
    if (resolvedId == null || resolvedId.trim().isEmpty) {
      final result = await _readLanIdentity(address, port);
      if (_disposed || generation != _connectionGeneration) return;
      resolvedId = result.deviceId;
      label = result.label;
    }
    if (resolvedId.isEmpty || resolvedId.length > 128 || resolvedId == identity?.deviceId) {
      throw const CompanionFailure('invalid_remote_identity');
    }
    await _connectEndpoint(
      CompanionEndpoint(
        deviceId: resolvedId,
        label: label,
        address: address,
        port: port,
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
        receiving: true,
      ),
      generation,
      automatic: false,
    );
  }

  Future<({String deviceId, String label})> _readLanIdentity(String address, int port) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .getUrl(Uri(scheme: 'http', host: address, port: port, path: '/companion/v1/identity'))
          .timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok) throw const CompanionFailure('remote_identity_unavailable');
      final bytes = await (() async {
        final result = <int>[];
        await for (final chunk in response) {
          if (result.length + chunk.length > 2048) throw const CompanionFailure('invalid_remote_identity');
          result.addAll(chunk);
        }
        return result;
      })().timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['deviceId'] is! String || decoded['label'] is! String) {
        throw const CompanionFailure('invalid_remote_identity');
      }
      final remoteId = decoded['deviceId'] as String;
      final remoteLabel = decoded['label'] as String;
      if (remoteId.isEmpty || remoteId.length > 128 || remoteLabel.length > 128) throw const CompanionFailure('invalid_remote_identity');
      return (deviceId: remoteId, label: remoteLabel.isEmpty ? 'TV' : remoteLabel);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> disconnect({bool rememberSelection = false}) async {
    await _detachClient(++_connectionGeneration, rememberSelection: rememberSelection);
  }

  Future<void> _detachClient(int generation, {required bool rememberSelection}) async {
    if (generation != _connectionGeneration) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final subscription = _clientSubscription;
    _clientSubscription = null;
    final channel = _client;
    _client = null;
    final stateReady = _authoritativeStateReady;
    _authoritativeStateReady = null;
    if (stateReady != null && !stateReady.isCompleted) {
      stateReady.completeError(const CompanionFailure('connection_lost'));
    }
    for (final pending in _commands.values) {
      if (!pending.isCompleted) pending.completeError(const CompanionFailure('connection_lost_result_unknown'));
    }
    _commands.clear();
    for (final pending in _requests.values) {
      if (!pending.isCompleted) pending.completeError(const CompanionFailure('connection_lost'));
    }
    _requests.clear();
    _controlAcquisition = null;
    connectionStatus = CompanionConnectionStatus.disconnected;
    Future<void>? remember;
    if (!rememberSelection) {
      _selectedId = null;
      remember = _repository.setSelectedDevice(null);
    }
    if (!_disposed) _notify();
    // Detach and fail only this connection's work before yielding. A newer
    // connection may start while the old socket and persistence are closing.
    await subscription?.cancel();
    await channel?.close();
    await remember;
  }

  Future<void> _lostConnection(String code) async {
    if (_client == null) return;
    final generation = ++_connectionGeneration;
    await _detachClient(generation, rememberSelection: true);
    if (_disposed || generation != _connectionGeneration) return;
    errorCode = code;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !_foreground || _selectedId == null || _reconnectTimer != null) return;
    final delay = [1, 2, 4, 8, 15, 30][_reconnectAttempts.clamp(0, 5)];
    _reconnectAttempts++;
    connectionStatus = CompanionConnectionStatus.reconnecting;
    _reconnectTimer = Timer(Duration(seconds: delay), () async {
      _reconnectTimer = null;
      final endpoint = endpoints[_selectedId];
      if (endpoint == null || endpoint.expiresAt.isBefore(DateTime.now()) || !endpoint.receiving) {
        _scheduleReconnect();
        return;
      }
      try {
        await connect(endpoint, automatic: true);
      } on Object {
        _scheduleReconnect();
      }
    });
    if (!_disposed) _notify();
  }

  Future<void> _receiveClient(Map<String, Object?> message, CompanionSecureChannel channel) async {
    if (_disposed || !identical(_client, channel)) return;

    _lastClientTick = _clock.elapsedMilliseconds;
    try {
      switch (message['kind']) {
        case 'welcome':
          final sequence = message['sequenceHighWater'];
          if (sequence is int && sequence > _clientSeq) _clientSeq = sequence;
        case 'state':
          final state = CompanionPlaybackSnapshot.fromJson(companionMap(message['state']));
          if (_clientEpoch != state.hostEpoch) {
            _clientEpoch = state.hostEpoch;
            remoteState = null;
          }
          if (remoteState != null && state.sequence <= remoteState!.sequence) return;
          remoteState = state;
          remoteStateAt = DateTime.now();
          _remoteStateTick = _clock.elapsedMilliseconds;
          final ready = _authoritativeStateReady;
          if (ready != null && !ready.isCompleted) ready.complete();
        case 'receipt':
          final receipt = CompanionReceipt.fromJson(message['receipt']);
          if (receipt.peerId != identity?.deviceId) return;
          lastReceipt = receipt;
          if (receipt.isTerminal) {
            final pending = _commands.remove(receipt.commandId);
            if (pending != null && !pending.isCompleted) pending.complete(receipt);
          }
        case 'response':
          final pending = _requests.remove(message['id']);
          if (pending == null || pending.isCompleted) return;
          if (message['error'] is String) {
            pending.completeError(CompanionFailure(message['error'] as String));
          } else {
            pending.complete(companionMap(message['result']));
          }
        case 'history':
          await _applyHistory(message['entries']);
        case 'pong':
          break;
        default:
          throw const CompanionFailure('unknown_message');
      }
      if (!_disposed && identical(_client, channel)) _notify();
    } on Object {
      if (!identical(_client, channel)) return;
      errorCode = 'invalid_remote_state';
      if (!_disposed) _notify();
    }
  }

  Future<CompanionReceipt> command(
    CompanionCommandType type, {
    Map<String, Object?> arguments = const {},
    bool ensureControl = true,
  }) async {
    final state = remoteState;
    final channel = _client;
    final target = _selectedId;
    if (_client == null || state == null || stale) throw const CompanionFailure('state_unavailable');
    if (ensureControl && type != CompanionCommandType.acquireControl && !hasControl) {
      final acquisition = _controlAcquisition ??= command(CompanionCommandType.acquireControl, ensureControl: false);
      late final CompanionReceipt acquired;
      try {
        acquired = await acquisition;
      } finally {
        if (identical(_controlAcquisition, acquisition)) _controlAcquisition = null;
      }
      if (acquired.phase != CompanionCommandPhase.applied) throw CompanionFailure(acquired.code ?? 'control_required');
      await _refreshState();
    }
    final current = remoteState!;
    if (!identical(channel, _client) || target != _selectedId || current.hostEpoch != state.hostEpoch) {
      throw const CompanionFailure('target_changed');
    }
    if (_commands.length >= 12) throw const CompanionFailure('too_many_commands');
    final age = _clock.elapsedMilliseconds - _remoteStateTick!;
    final outgoing = CompanionCommand(
      id: companionToken(),
      hostEpoch: current.hostEpoch,
      clientSeq: ++_clientSeq,
      controlGeneration: current.controlGeneration,
      playbackGeneration: current.playbackGeneration,
      deadlineMs: current.serverMs + age + 4000,
      type: type,
      arguments: arguments,
    );
    final completion = Completer<CompanionReceipt>();
    completion.future.ignore();
    _commands[outgoing.id] = completion;
    try {
      await channel!.send({'kind': 'command', 'command': outgoing.toJson()});
      return await completion.future.timeout(
        const Duration(seconds: 35),
        onTimeout: () {
          _commands.remove(outgoing.id);
          throw const CompanionFailure('command_result_unknown');
        },
      );
    } finally {
      _commands.remove(outgoing.id);
    }
  }

  Future<void> _refreshState() async {
    final before = remoteState?.sequence ?? 0;
    await _client?.send({'kind': 'stateRequest'});
    final timer = Stopwatch()..start();
    while ((remoteState?.sequence ?? 0) <= before) {
      if (_client == null || timer.elapsed > const Duration(seconds: 3)) throw const CompanionFailure('state_unavailable');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<Map<String, Object?>> request(String method, {Map<String, Object?> arguments = const {}}) async {
    if (_client == null) throw const CompanionFailure('not_connected');
    if (_requests.length >= 4) throw const CompanionFailure('too_many_requests');
    final id = companionToken();
    final completion = Completer<Map<String, Object?>>();
    completion.future.ignore();
    _requests[id] = completion;
    try {
      await _client!.send({'kind': 'request', 'id': id, 'method': method, 'arguments': arguments});
      return await completion.future.timeout(const Duration(seconds: 30));
    } finally {
      _requests.remove(id);
    }
  }

  Future<CompanionReceipt> handoff(CompanionContentRef content) async {
    final interaction = await beginInteraction();
    final getLibrary = ref.read(companionLibraryProvider);
    final oldBinding = _media.active;
    final oldContent = _media.content;
    var baseRevision = getLibrary == null ? 0 : (await (await getLibrary()).readVideoHistory(content.identity))?.revision ?? 0;
    final result = await interactionCommand(interaction, CompanionCommandType.handoff, arguments: content.toJson());
    if (result.phase == CompanionCommandPhase.started) {
      if (oldBinding != null &&
          identical(oldBinding, _media.active) &&
          oldContent?.identity == content.identity &&
          oldContent?.groupId == content.groupId &&
          oldContent?.episodeId == content.episodeId) {
        await oldBinding.controller.pause();
        if (getLibrary != null) {
          final after = await (await getLibrary()).readVideoHistory(content.identity);
          if (after?.checkpoint.playbackSessionId == oldBinding.sessionId) baseRevision = after!.revision;
        }
      }
      final session = result.details['playbackSessionId'];
      if (session is String) {
        final progressKey = jsonEncode([interaction.deviceId, content.identity]);
        _remoteProgressSessions[progressKey] = session;
        _remoteProgressRevisions[progressKey] = baseRevision;
        if (_remoteProgressSessions.length > 1000) {
          final oldest = _remoteProgressSessions.keys.first;
          _remoteProgressSessions.remove(oldest);
          _remoteProgressRevisions.remove(oldest);
        }
      }
    }
    return result;
  }

  Future<void> _applyHistory(Object? value) async {
    if (value is! List || value.length > 20) throw const CompanionFailure('invalid_history');
    final getLibrary = ref.read(companionLibraryProvider);
    if (getLibrary == null || _selectedId == null) return;
    final channel = _client;
    final peerId = _selectedId;
    final acknowledgements = <Map<String, Object?>>[];
    final library = await getLibrary();
    for (final raw in value) {
      final checkpoint = VideoHistoryCheckpoint.fromJson(companionMap(raw));
      if (checkpoint.originDeviceId != peerId) continue;
      final key = jsonEncode([checkpoint.originDeviceId, checkpoint.playbackSessionId, checkpoint.sourceKey]);
      final ack = {
        'key': jsonEncode([checkpoint.sourceKey, checkpoint.playbackSessionId]),
        'sequence': checkpoint.sequence,
      };
      if ((_remoteProgressSequences[key] ?? -1) >= checkpoint.sequence) {
        acknowledgements.add(ack);
        continue;
      }
      final previous = await library.readVideoHistory(checkpoint.sourceKey);
      if (!identical(channel, _client) || _selectedId != peerId) return;
      final progressKey = jsonEncode([peerId, checkpoint.sourceKey]);
      final delegated = _remoteProgressSessions[progressKey] == checkpoint.playbackSessionId;
      final alreadyFollowing =
          previous?.checkpoint.originDeviceId == checkpoint.originDeviceId &&
          previous?.checkpoint.playbackSessionId == checkpoint.playbackSessionId;
      // Merely connecting to a TV does not authorize its old history to replace
      // a different local session. Such records are retained as remote branches.
      final expected = delegated
          ? _remoteProgressRevisions[progressKey] ?? 0
          : alreadyFollowing
          ? _remoteProgressRevisions.putIfAbsent(progressKey, () => previous?.revision ?? 0)
          : 0;
      final result = await library.saveVideoHistory(checkpoint, expectedLocalRevision: expected, remote: true);
      _remoteProgressSequences[key] = checkpoint.sequence;
      if (_remoteProgressSequences.length > 1000) _remoteProgressSequences.remove(_remoteProgressSequences.keys.first);
      if (result.status == VideoHistorySaveStatus.committed) _remoteProgressRevisions[progressKey] = result.revision;
      if (_remoteProgressRevisions.length > 1000) {
        final oldest = _remoteProgressRevisions.keys.first;
        _remoteProgressRevisions.remove(oldest);
        _remoteProgressSessions.remove(oldest);
      }
      acknowledgements.add(ack);
    }
    if (identical(channel, _client) && channel != null && acknowledgements.isNotEmpty) {
      await channel.send({'kind': 'historyAck', 'entries': acknowledgements});
    }
  }
}
