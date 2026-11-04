/// Receiver-side authorization, real state projection and command dispatch.
/// This part never resolves a phone supplied URL or persists candidate progress.
part of 'companion_controller.dart';

extension CompanionReceiver on CompanionController {
  Future<CompanionReceipt> _dispatchCommand(String peerId, CompanionCommand command, CompanionExecutionContext context) async {
    try {
      return await _executeCommand(peerId, command, context);
    } on CompanionCommandCancelledException {
      rethrow;
    } on Object catch (error) {
      return CompanionReceipt(peerId: peerId, commandId: command.id, phase: CompanionCommandPhase.failed, code: _safeCode(error));
    }
  }

  Future<bool> _acceptRequest(HttpRequest request) async {
    if (request.uri.path == '/companion/v1/identity') {
      final remote = request.connectionInfo?.remoteAddress.address;
      if (request.method != 'GET' || !_isPrivateLanAddress(remote) || !receiverEnabled || !_foreground || _disposed || identity == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'deviceId': identity!.deviceId, 'label': identity!.label}));
      }
      await request.response.close();
      return true;
    }
    if (request.uri.path != '/companion/v1/ws') return false;
    final remoteAddress = request.connectionInfo?.remoteAddress.address;
    if (!receiverEnabled ||
        !_foreground ||
        _disposed ||
        identity == null ||
        !_isPrivateLanAddress(remoteAddress) ||
        _peers.length + _pendingHandshakes >= 4 ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return true;
    }
    _pendingHandshakes++;
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      final channel = await CompanionSecureChannel.accept(
        socket: socket,
        localDeviceId: identity!.deviceId,
        resolvePeerSecret: (id) async => await _trusted(id) ? _identities.readPeerSecret(id) : null,
        allowLanSession: true,
      );
      if (!await _trusted(channel.peerDeviceId, lanSession: channel.isLanSession)) {
        await channel.close();
        return true;
      }
      _disconnectPeer(channel.peerDeviceId);
      final peer = _CompanionPeer(channel.peerDeviceId, channel);
      _peers[peer.id] = peer;
      peer.subscription = channel.messages.listen(
        (message) => unawaited(_receivePeer(peer, message)),
        onError: (Object _) => _disconnectPeer(peer.id, expected: peer),
        onDone: () => _disconnectPeer(peer.id, expected: peer),
      );
      await _sendPeer(peer, {'kind': 'welcome', 'sequenceHighWater': _engine.getPeerSequenceHighWater(peer.id)});
      await _sendPeer(peer, {'kind': 'state', 'state': (await _snapshot()).toJson()});
      await _pushHistory(peer);
      if (!_disposed) _notify();
    } on Object {
      /* Authentication failures reveal no device metadata. */
    } finally {
      _pendingHandshakes--;
    }
    return true;
  }

  Future<void> _receivePeer(_CompanionPeer peer, Map<String, Object?> message) async {
    try {
      if (!identical(_peers[peer.id], peer)) return;
      if (peer.rateClock.elapsedMilliseconds >= 1000) {
        peer.rateClock.reset();
        peer.messageCount = 0;
      }
      if (++peer.messageCount > 40) {
        _disconnectPeer(peer.id);
        return;
      }
      if (!await _peerAuthorized(peer.id)) {
        _disconnectPeer(peer.id, expected: peer);
        return;
      }
      if (!identical(_peers[peer.id], peer)) return;
      peer.lastSeen = DateTime.now();
      switch (message['kind']) {
        case 'ping':
          if (message['control'] == true) _engine.renewControl(peer.id);
          await _sendPeer(peer, {'kind': 'pong'});
        case 'command':
          final command = CompanionCommand.fromJson(message['command']);
          final result = await _engine.execute(peer.id, command);
          if (command.type == CompanionCommandType.releaseControl) _textInput.disconnect(peer.id);
          await _sendPeer(peer, {'kind': 'receipt', 'receipt': result.toJson()});
          await _broadcastSnapshot();
        case 'request':
          final id = companionText(message, 'id', max: 128);
          if (peer.requests >= 3) {
            await _sendPeer(peer, {'kind': 'response', 'id': id, 'error': 'receiver_busy'});
            return;
          }
          peer.requests++;
          try {
            final result = await _catalogRequest(peer.id, companionText(message, 'method', max: 64), companionMap(message['arguments']))
                .timeout(
                  const Duration(seconds: 28),
                  onTimeout: () {
                    _searchCancellations.remove(peer.id)?.cancel();
                    throw const CompanionFailure('request_timeout');
                  },
                );
            if (utf8.encode(jsonEncode(result)).length > 60 * 1024) throw const CompanionFailure('response_too_large');
            if (await _peerAuthorized(peer.id)) await _sendPeer(peer, {'kind': 'response', 'id': id, 'result': result});
          } on Object catch (error) {
            await _sendPeer(peer, {'kind': 'response', 'id': id, 'error': _safeCode(error)});
          } finally {
            peer.requests--;
          }
        case 'cancelSearch':
          _searchCancellations.remove(peer.id)?.cancel();
        case 'historyAck':
          final entries = message['entries'];
          if (entries is! List || entries.length > 20) throw const CompanionFailure('invalid_history_ack');
          for (final raw in entries) {
            final item = companionMap(raw);
            final key = companionText(item, 'key', max: 4096);
            peer.historyWatermarks[key] = companionInt(item, 'sequence');
            if (peer.historyWatermarks.length > 500) peer.historyWatermarks.remove(peer.historyWatermarks.keys.first);
          }
        case 'stateRequest':
          await _sendPeer(peer, {'kind': 'state', 'state': (await _snapshot()).toJson()});
        default:
          throw const CompanionFailure('unknown_message');
      }
    } on Object {
      _disconnectPeer(peer.id, expected: peer);
    }
  }

  Future<CompanionPlaybackSnapshot> _snapshot() async {
    final binding = _media.active?.privateContent == true ? null : _media.active;
    final state = binding?.controller.snapshot;
    double? systemVolume;
    if (binding?.canSystemVolume == true) {
      try {
        systemVolume = await binding!.systemVolumeRead();
      } on Object {
        /* Capability read can fail. */
      }
    }
    return CompanionPlaybackSnapshot(
      sequence: ++_snapshotSequence,
      hostEpoch: hostEpoch,
      serverMs: _engine.serverNowMs,
      controlGeneration: _engine.controlGeneration,
      playbackGeneration: _engine.playbackGeneration,
      controllerId: _engine.controlOwnerId,
      content: _media.content,
      playbackSessionId: binding?.sessionId,
      status: state == null
          ? 'idle'
          : state.failure != null
          ? 'failed'
          : state.buffering
          ? 'buffering'
          : !state.firstFrameReady
          ? 'preparing'
          : state.completed
          ? 'completed'
          : state.playing
          ? 'playing'
          : 'paused',
      playing: state?.playing ?? false,
      buffering: state?.buffering ?? false,
      firstFrame: state?.firstFrameReady ?? false,
      positionMs: state?.position.inMilliseconds ?? 0,
      durationMs: state?.duration.inMilliseconds ?? 0,
      bufferedMs: state?.bufferedPosition.inMilliseconds ?? 0,
      rate: state?.rate ?? 1,
      volume: state?.volume ?? 100,
      hasPrevious: state?.hasPreviousEpisode ?? false,
      hasNext: state?.hasNextEpisode ?? false,
      failureCode: state?.failure?.code,
      saveFailure: binding?.onSaveFailure?.call() ?? false,
      canSystemVolume: binding?.canSystemVolume ?? false,
      systemVolume: systemVolume,
      receiving: receiverEnabled && _foreground,
      groups: [
        for (final group in (state?.groups ?? const <VideoEpisodeGroup>[]).where((group) => group.id == state?.activeGroupId).take(1))
          CompanionEpisodeGroup(
            id: group.id,
            title: group.title,
            deferred: group.deferred,
            episodes: [
              for (final episode in group.episodes.where((episode) => episode.id == state?.activeEpisodeId).take(1))
                CompanionEpisode(episode.id, episode.title),
            ],
          ),
      ],
    );
  }

  Future<void> _broadcastSnapshot() async {
    if (_peers.isEmpty) return;
    final state = (await _snapshot()).toJson();
    for (final peer in _peers.values.toList()) {
      await _sendPeer(peer, {'kind': 'state', 'state': state});
    }
  }

  Future<void> _pushHistory(_CompanionPeer peer) async {
    try {
      final getLibrary = ref.read(companionLibraryProvider);
      if (getLibrary == null) return;
      final library = await getLibrary();
      final history = await library.listVideoHistory(limit: 500);
      final lanSession = _isLanSession(peer.id);
      final allowHistory = lanSession || (await _repository.policy(peer.id)).browseLibrary;
      final normalItems = await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount, visibility: LibraryVisibility.normal));
      final normalVideoKeys = {
        for (final item in normalItems.items.where((item) => item.kind == ContentKind.video))
          videoHistorySourceKey(item.source.pluginId, item.source.remoteContentId),
      };
      final allowed = history
          .where(
            (entry) =>
                entry.checkpoint.originDeviceId == identity?.deviceId &&
                (entry.checkpoint.controllerDeviceId == peer.id ||
                    entry.checkpoint.playbackSessionId == _media.active?.sessionId ||
                    allowHistory) &&
                (normalVideoKeys.contains(entry.checkpoint.sourceKey) ||
                    entry.checkpoint.controllerDeviceId == peer.id ||
                    (entry.checkpoint.playbackSessionId == _media.active?.sessionId && _media.active?.privateContent != true)),
          )
          .toList();
      final keys = {
        for (final entry in allowed) jsonEncode([entry.checkpoint.sourceKey, entry.checkpoint.playbackSessionId]),
      };
      peer.historyWatermarks.removeWhere((key, _) => !keys.contains(key));
      final entries = <Map<String, Object?>>[];
      var bytes = 0;
      for (final entry in allowed) {
        final checkpoint = entry.checkpoint;
        final key = jsonEncode([checkpoint.sourceKey, checkpoint.playbackSessionId]);
        if ((peer.historyWatermarks[key] ?? -1) >= checkpoint.sequence) continue;
        final json = checkpoint.toJson();
        final size = utf8.encode(jsonEncode(json)).length;
        if (entries.length >= 20 || bytes + size > 48 * 1024) break;
        entries.add(json);
        bytes += size;
      }
      if (entries.isNotEmpty) await _sendPeer(peer, {'kind': 'history', 'entries': entries});
    } on Object {
      /* The state snapshot reports playback-save failures separately. */
    }
  }

  Future<CompanionReceipt> _executeCommand(String peerId, CompanionCommand command, CompanionExecutionContext context) async {
    if (!await _peerAuthorized(peerId)) throw const CompanionFailure('authorization_revoked');
    context.ensureCurrent();
    final args = command.arguments;
    final binding = _media.active?.privateContent == true ? null : _media.active;
    final player = binding?.controller;
    CompanionReceipt done({Map<String, Object?> details = const {}}) =>
        CompanionReceipt(peerId: peerId, commandId: command.id, phase: CompanionCommandPhase.applied, details: details);
    if (command.type == CompanionCommandType.handoff) {
      context.report(CompanionCommandPhase.preparing);
      final content = CompanionContentRef.fromJson(args);
      _remoteMediaMutation++;
      try {
        await ref.read(companionHandoffLauncherProvider)(content, context);
      } finally {
        _remoteMediaMutation--;
      }
      return CompanionReceipt(
        peerId: peerId,
        commandId: command.id,
        phase: CompanionCommandPhase.started,
        details: {'playbackSessionId': _media.active?.sessionId},
      );
    }
    if (command.type == CompanionCommandType.beginTextInput) {
      await ref.read(companionOpenSearchProvider)();
      context.ensureCurrent();
      return done(details: ref.read(companionTextInputProvider).begin(peerId, companionToken()));
    }
    if (command.type == CompanionCommandType.updateTextInput) {
      return done(details: ref.read(companionTextInputProvider).update(peerId, args));
    }
    if (command.type == CompanionCommandType.submitTextInput) {
      ref.read(companionTextInputProvider).submit(peerId, args);
      return done();
    }
    if (command.type == CompanionCommandType.cancelTextInput) {
      ref.read(companionTextInputProvider).cancel(peerId, args);
      return done();
    }
    if (command.type == CompanionCommandType.navigate) {
      final key = companionText(args, 'key', max: 16);
      if (!{'up', 'down', 'left', 'right', 'confirm', 'back'}.contains(key)) throw const CompanionFailure('invalid_key');
      await ref.read(companionNavigateProvider)(key);
      return done();
    }
    if (player == null || binding == null) throw const CompanionFailure('no_active_playback');
    switch (command.type) {
      case CompanionCommandType.play:
        await player.play();
        await _waitPlayback(() => player.snapshot.playing, context);
      case CompanionCommandType.pause:
        await player.pause();
        await _waitPlayback(() => !player.snapshot.playing, context);
      case CompanionCommandType.seek:
        final position = companionInt(args, 'positionMs');
        final duration = player.snapshot.duration.inMilliseconds;
        if (duration <= 0) throw const CompanionFailure('seek_unavailable');
        final target = position.clamp(0, duration);
        await player.seek(Duration(milliseconds: target));
        await _waitPlayback(() => (player.snapshot.position.inMilliseconds - target).abs() <= 2000, context);
      case CompanionCommandType.setRate:
        final value = args['rate'];
        if (value is! num || !value.isFinite || value < .25 || value > 3) throw const CompanionFailure('invalid_rate');
        await player.setRate(value.toDouble());
        await _waitPlayback(() => (player.snapshot.rate - value).abs() < .01, context);
      case CompanionCommandType.setVolume:
        final value = args['volume'];
        if (value is! num || !value.isFinite || value < 0 || value > 100) throw const CompanionFailure('invalid_volume');
        await player.setVolume(value.toDouble());
        await _waitPlayback(() => (player.snapshot.volume - value).abs() < 1, context);
      case CompanionCommandType.setSystemVolume:
        if (!binding.canSystemVolume) throw const CompanionFailure('system_volume_unavailable');
        final value = args['volume'];
        if (value is! num || !value.isFinite || value < 0 || value > 100) throw const CompanionFailure('invalid_volume');
        await binding.systemVolumeWrite(value.toDouble());
        final actual = await binding.systemVolumeRead();
        if (actual == null || (actual - value).abs() > 8) throw const CompanionFailure('system_volume_not_applied');
      case CompanionCommandType.setMuted:
        final muted = args['muted'];
        if (muted is! bool) throw const CompanionFailure('invalid_mute');
        if ((player.snapshot.volume == 0) != muted) await player.toggleMute();
        await _waitPlayback(() => (player.snapshot.volume == 0) == muted, context);
      case CompanionCommandType.previousEpisode:
      case CompanionCommandType.nextEpisode:
      case CompanionCommandType.selectEpisode:
        final content = _media.content!;
        var groupId = content.groupId;
        var episodeId = content.episodeId;
        if (command.type == CompanionCommandType.selectEpisode) {
          groupId = companionText(args, 'groupId');
          episodeId = companionText(args, 'episodeId');
        } else {
          final group = player.snapshot.groups.where((group) => group.id == groupId).firstOrNull;
          if (group == null) throw const CompanionFailure('episode_unavailable');
          final index = group.episodes.indexWhere((episode) => episode.id == episodeId);
          final next = index + (command.type == CompanionCommandType.nextEpisode ? 1 : -1);
          if (index < 0 || next < 0 || next >= group.episodes.length) throw const CompanionFailure('episode_unavailable');
          episodeId = group.episodes[next].id;
        }
        _remoteMediaMutation++;
        try {
          await ref.read(companionHandoffLauncherProvider)(
            CompanionContentRef(
              pluginId: content.pluginId,
              pluginVersion: content.pluginVersion,
              contentId: content.contentId,
              title: content.title,
              groupId: groupId,
              episodeId: episodeId,
            ),
            context,
          );
        } finally {
          _remoteMediaMutation--;
        }
      case CompanionCommandType.exitPlayback:
        await player.requestExit();
      default:
        throw const CompanionFailure('command_unsupported');
    }
    return done();
  }

  Future<void> _waitPlayback(bool Function() reached, CompanionExecutionContext context) async {
    final clock = Stopwatch()..start();
    while (!reached()) {
      context.ensureCurrent();
      if (clock.elapsed > const Duration(seconds: 3)) throw const CompanionFailure('playback_state_timeout');
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  String _safeCode(Object error) => error is CompanionFailure
      ? error.code
      : error is VideoPlayerLoadException
      ? error.code
      : 'operation_failed';
}

bool _isPrivateLanAddress(String? address) {
  if (address == null) return false;
  final normalized = address.startsWith('::ffff:') ? address.substring(7) : address;
  return isLanSyncPrivateIpv4(normalized) || normalized == '127.0.0.1';
}

final companionOpenSearchProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    throw const CompanionFailure('search_unavailable');
  },
);
final companionNavigateProvider = Provider<Future<void> Function(String)>(
  (ref) => (_) async {
    throw const CompanionFailure('navigation_unavailable');
  },
);
final companionNavigationGuardProvider = Provider<CompanionNavigationGuard>((ref) => CompanionNavigationGuard());

final class CompanionNavigationGuard {
  final Map<Object, bool Function()?> _owners = {};
  bool get protected => _owners.values.any((isCurrent) => isCurrent?.call() ?? true);
  void enter(Object owner, {bool Function()? isCurrent}) => _owners[owner] = isCurrent;
  void leave(Object owner) => _owners.remove(owner);
}
