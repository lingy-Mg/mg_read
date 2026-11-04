/// App-owned registration of the existing video host. This bridge owns no
/// backend, source Runtime or route; the mounted media destination owns them.
library;

import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import '../domain/companion_models.dart';

final companionMediaHostProvider = Provider<CompanionMediaHost>((ref) {
  final host = CompanionMediaHost();
  ref.onDispose(host.dispose);
  return host;
});

final class CompanionMediaBinding {
  CompanionMediaBinding({
    required this.owner,
    required this.controller,
    required this.content,
    required this.sessionId,
    required this.systemVolumeRead,
    required this.systemVolumeWrite,
    this.canSystemVolume = false,
    this.privateContent = false,
    this.onSaveFailure,
    this.route,
  });
  final Object owner;
  final Route<dynamic>? route;
  final VideoPlayerController controller;
  final CompanionContentRef content;
  final String sessionId;
  final Future<double?> Function() systemVolumeRead;
  final Future<void> Function(double) systemVolumeWrite;
  final bool canSystemVolume;
  final bool privateContent;
  final bool Function()? onSaveFailure;
}

final class CompanionMediaHost extends ChangeNotifier {
  CompanionMediaBinding? _active;
  CompanionMediaBinding? get active => _active;
  CompanionContentRef? get content {
    final binding = _active;
    if (binding == null || binding.privateContent) return null;
    final snapshot = binding.controller.snapshot;
    return CompanionContentRef(
      pluginId: binding.content.pluginId,
      contentId: binding.content.contentId,
      pluginVersion: binding.content.pluginVersion,
      title: binding.content.title,
      groupId: snapshot.activeGroupId ?? binding.content.groupId,
      episodeId: snapshot.activeEpisodeId ?? binding.content.episodeId,
      positionMs: snapshot.position.inMilliseconds,
    );
  }

  void register(CompanionMediaBinding binding) {
    _active?.controller.removeListener(_changed);
    _active = binding;
    binding.controller.addListener(_changed);
    notifyListeners();
  }

  void unregister(Object owner) {
    if (!identical(_active?.owner, owner)) return;
    _active?.controller.removeListener(_changed);
    _active = null;
    notifyListeners();
  }

  void _changed() => notifyListeners();
  @override
  void dispose() {
    _active?.controller.removeListener(_changed);
    super.dispose();
  }
}
