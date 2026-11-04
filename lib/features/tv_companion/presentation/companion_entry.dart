/// Global entry and visible target badge. It never silently selects another TV
/// or infers connectivity from an unauthenticated discovery announcement.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/companion_controller.dart';
import '../domain/companion_models.dart';

class CompanionEntry extends ConsumerWidget {
  const CompanionEntry({required this.onOpen, required this.tvMode, this.overlayContext, super.key});
  final VoidCallback onOpen;
  final bool tvMode;
  final BuildContext? Function()? overlayContext;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(companionControllerProvider);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: EdgeInsets.only(right: 16, bottom: tvMode ? 20 : 88),
            child: Wrap(
              spacing: 8,
              children: [
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
