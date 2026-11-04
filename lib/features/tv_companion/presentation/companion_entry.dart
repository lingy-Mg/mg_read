/// Global entry and visible target badge. It never silently selects another TV
/// or infers connectivity from an unauthenticated discovery announcement.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/companion_controller.dart';
import '../application/companion_media_host.dart';
import '../domain/companion_models.dart';
import '../domain/companion_command.dart';
import 'companion_messages.dart';

class CompanionEntry extends ConsumerWidget {
  const CompanionEntry({required this.onOpen, required this.tvMode, this.overlayContext, super.key});
  final VoidCallback onOpen;
  final bool tvMode;
  final BuildContext? Function()? overlayContext;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(companionControllerProvider);
    final media = ref.watch(companionMediaHostProvider);
    return AnimatedBuilder(
      animation: Listenable.merge([service, media]),
      builder: (context, _) => SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: EdgeInsets.only(right: 16, bottom: tvMode ? 20 : 88),
            child: Wrap(
              spacing: 8,
              children: [
                if (!tvMode && media.content != null)
                  IconButton.filledTonal(
                    tooltip: '将当前视频接续到 TV',
                    icon: const Icon(Icons.connected_tv),
                    onPressed: () => sendCurrentVideoToTv(overlayContext?.call() ?? context, ref, onOpen),
                  ),
                FilledButton.tonalIcon(
                  onPressed: onOpen,
                  icon: Icon(tvMode ? Icons.phonelink : Icons.tv),
                  label: Text(
                    tvMode
                        ? '手机连接'
                        : service.connectionStatus == CompanionConnectionStatus.connected
                        ? '${service.selectedLabel} · ${service.stale ? '状态延迟' : '已连接'}'
                        : '连接 TV',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> sendCurrentVideoToTv(BuildContext context, WidgetRef ref, VoidCallback onOpen) async {
  final service = ref.read(companionControllerProvider);
  final media = ref.read(companionMediaHostProvider);
  final content = media.content;
  if (content == null) return;
  if (service.connectionStatus != CompanionConnectionStatus.connected) {
    onOpen();
    return;
  }
  final currentTv = service.remoteState?.content;
  final sameEpisode =
      !service.stale &&
      currentTv?.identity == content.identity &&
      currentTv?.groupId == content.groupId &&
      currentTv?.episodeId == content.episodeId;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('在 ${service.selectedLabel} 接着播放？'),
      content: Text(
        '《${content.title}》将从 ${(content.positionMs / 60000).floor()} 分 ${(content.positionMs / 1000).floor() % 60} 秒开始。TV 起播后才暂停手机。',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (sameEpisode) TextButton(onPressed: () => Navigator.pop(context, 'tv'), child: const Text('继续 TV 当前进度')),
        FilledButton(onPressed: () => Navigator.pop(context, 'phone'), child: const Text('使用手机进度')),
      ],
    ),
  );
  if (choice == null) return;
  try {
    final result = await service.handoff(
      choice == 'tv'
          ? CompanionContentRef(
              pluginId: content.pluginId,
              pluginVersion: content.pluginVersion,
              contentId: content.contentId,
              title: content.title,
              groupId: content.groupId,
              episodeId: content.episodeId,
              useTvProgress: true,
            )
          : content,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.phase == CompanionCommandPhase.started ? 'TV 已实际起播' : companionErrorText(result.code))));
    }
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(companionErrorText(error is CompanionFailure ? error.code : 'operation_failed'))));
    }
  }
}
