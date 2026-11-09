/// Player-styled presentation of settings that do not belong beside progress.
///
/// Responsibilities:
/// - Keep episode navigation, repeat, rate and fit controls in one visual panel.
/// - Use a narrow, fine-grained menu without changing TV or shared chrome.
///
/// Notes:
/// - This panel only emits existing chrome callbacks and owns no playback state.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';
import 'video_player_modal.dart';
import 'video_player_compact_panel.dart';

Future<void> showVideoPlayerSettingsSheet({
  required BuildContext context,
  required VideoPlayerSnapshot snapshot,
  required Future<void> Function(double) onRate,
  required Future<void> Function(VideoEnhancementMode) onEnhancementMode,
  required Future<void> Function() onFit,
  required Future<void> Function() onPreviousEpisode,
  required Future<void> Function() onNextEpisode,
  required Future<void> Function(bool) onAutoAdvance,
}) => showVideoPlayerModal<void>(
  context: context,
  maxWidth: 360,
  builder: (_) => Theme(
    data: videoPlayerTheme(),
    child: _VideoPlayerSettingsSheet(
      snapshot: snapshot,
      onRate: onRate,
      onEnhancementMode: onEnhancementMode,
      onFit: onFit,
      onPreviousEpisode: onPreviousEpisode,
      onNextEpisode: onNextEpisode,
      onAutoAdvance: onAutoAdvance,
    ),
  ),
);

final class _VideoPlayerSettingsSheet extends StatefulWidget {
  const _VideoPlayerSettingsSheet({
    required this.snapshot,
    required this.onRate,
    required this.onEnhancementMode,
    required this.onFit,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onAutoAdvance,
  });

  final VideoPlayerSnapshot snapshot;
  final Future<void> Function(double) onRate;
  final Future<void> Function(VideoEnhancementMode) onEnhancementMode;
  final Future<void> Function() onFit;
  final Future<void> Function() onPreviousEpisode;
  final Future<void> Function() onNextEpisode;
  final Future<void> Function(bool) onAutoAdvance;

  @override
  State<_VideoPlayerSettingsSheet> createState() =>
      _VideoPlayerSettingsSheetState();
}

final class _VideoPlayerSettingsSheetState
    extends State<_VideoPlayerSettingsSheet> {
  late double _rate = widget.snapshot.rate;
  late VideoFitMode _fitMode = widget.snapshot.fitMode;
  late bool _autoAdvance = widget.snapshot.autoAdvance;
  late VideoEnhancementMode _enhancementMode = widget.snapshot.enhancementMode;

  Future<void> _setRate(double rate) async {
    await widget.onRate(rate);
    if (mounted) setState(() => _rate = rate);
  }

  Future<void> _cycleFitMode() async {
    await widget.onFit();
    if (mounted) {
      setState(() {
        _fitMode = VideoFitMode
            .values[(_fitMode.index + 1) % VideoFitMode.values.length];
      });
    }
  }

  Future<void> _setAutoAdvance(bool enabled) async {
    await widget.onAutoAdvance(enabled);
    if (mounted) setState(() => _autoAdvance = enabled);
  }

  Future<void> _setEnhancementMode(bool enabled) async {
    final mode = enabled
        ? VideoEnhancementMode.anime4kFast
        : VideoEnhancementMode.off;
    try {
      await widget.onEnhancementMode(mode);
      if (mounted) setState(() => _enhancementMode = mode);
    } on Object {
      // A missing or unsupported native shader leaves the current mode intact.
    }
  }

  @override
  Widget build(BuildContext context) {
    final pointer = videoPlayerUsesPointerControls(context);
    return VideoPlayerCompactPanel(
      key: const Key('video-player-settings-sheet'),
      title: '播放设置',
      closeKey: const Key('video-player-settings-close'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 2, bottom: 6),
              child: Text(
                '播放速度',
                style: TextStyle(color: videoPlayerSecondary, fontSize: 11),
              ),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final rate in _rates)
                  ChoiceChip(
                    key: Key('video-player-rate-${_rateKey(rate)}'),
                    label: Text('${_trimRate(rate)}×'),
                    selected: _rate == rate,
                    showCheckmark: false,
                    selectedColor: videoPlayerAccent.withValues(alpha: .18),
                    backgroundColor: const Color(0x0AFFFFFF),
                    side: BorderSide(
                      color: _rate == rate
                          ? videoPlayerAccent.withValues(alpha: .65)
                          : const Color(0x14FFFFFF),
                      width: .5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: pointer
                        ? MaterialTapTargetSize.shrinkWrap
                        : MaterialTapTargetSize.padded,
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 9),
                    labelStyle: TextStyle(
                      color: _rate == rate
                          ? Colors.white
                          : videoPlayerSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    onSelected: (_) => _setRate(rate),
                  ),
              ],
            ),
            const _MenuDivider(),
            _SettingsRow(
              icon: Icons.repeat_rounded,
              label: '自动连播',
              detail: _autoAdvance ? '当前开启' : '当前关闭',
              onTap: () => _setAutoAdvance(!_autoAdvance),
              trailing: _smallSwitch(
                context,
                key: const Key('video-player-auto-advance'),
                value: _autoAdvance,
                onChanged: _setAutoAdvance,
              ),
            ),
            _SettingsRow(
              icon: Icons.aspect_ratio_rounded,
              label: '画面比例',
              detail: _fitLabel(_fitMode),
              detailHint: _fitMode == VideoFitMode.contain ? '默认' : null,
              onTap: _cycleFitMode,
              trailing: TextButton(
                key: const Key('video-player-fit'),
                onPressed: _cycleFitMode,
                style: TextButton.styleFrom(
                  foregroundColor: videoPlayerSecondary,
                  minimumSize: Size(44, pointer ? 32 : 44),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('切换', style: TextStyle(fontSize: 11)),
              ),
            ),
            _SettingsRow(
              icon: Icons.auto_awesome_outlined,
              label: '动漫高清修复',
              detail: _enhancementMode == VideoEnhancementMode.off
                  ? '当前关闭'
                  : 'Anime4K 快速模式',
              onTap: () => _setEnhancementMode(
                _enhancementMode == VideoEnhancementMode.off,
              ),
              trailing: _smallSwitch(
                context,
                key: const Key('video-player-anime4k'),
                value: _enhancementMode != VideoEnhancementMode.off,
                onChanged: _setEnhancementMode,
              ),
            ),
            const _MenuDivider(),
            Row(
              children: [
                Expanded(
                  child: _EpisodeAction(
                    key: const Key('video-player-previous-episode'),
                    icon: Icons.skip_previous_rounded,
                    label: '上一集',
                    enabled:
                        widget.snapshot.hasPreviousEpisode ||
                        widget.snapshot.position >= const Duration(seconds: 5),
                    onPressed: widget.onPreviousEpisode,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _EpisodeAction(
                    key: const Key('video-player-next-episode'),
                    icon: Icons.skip_next_rounded,
                    label: '下一集',
                    enabled: widget.snapshot.hasNextEpisode,
                    onPressed: widget.onNextEpisode,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Widget _smallSwitch(
  BuildContext context, {
  required Key key,
  required bool value,
  required ValueChanged<bool> onChanged,
}) => SizedBox(
  width: 44,
  height: videoPlayerUsesPointerControls(context) ? 36 : 44,
  child: Transform.scale(
    scale: .76,
    child: Switch.adaptive(
      key: key,
      value: value,
      activeTrackColor: videoPlayerAccent,
      onChanged: onChanged,
    ),
  ),
);

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 7),
    child: Divider(height: 1, color: Color(0x14FFFFFF)),
  );
}

final class _EpisodeAction extends StatelessWidget {
  const _EpisodeAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    super.key,
  });
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: enabled ? onPressed : null,
    style: TextButton.styleFrom(
      foregroundColor: videoPlayerSecondary,
      backgroundColor: const Color(0x08FFFFFF),
      disabledForegroundColor: const Color(0x55FFFFFF),
      minimumSize: Size(44, videoPlayerUsesPointerControls(context) ? 32 : 44),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    icon: Icon(icon, size: 16),
    label: Text(
      label,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
    ),
  );
}

final class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.trailing,
    required this.onTap,
    this.detailHint,
  });
  final IconData icon;
  final String label, detail;
  final Widget trailing;
  final String? detailHint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: videoPlayerSecondary, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: videoPlayerForeground,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    key: detailHint == null
                        ? null
                        : const Key('video-player-fit-default-hint'),
                    TextSpan(
                      children: [
                        TextSpan(text: detail),
                        if (detailHint case final hint?)
                          TextSpan(
                            text: '  $hint',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                    style: const TextStyle(
                      color: videoPlayerSecondary,
                      fontSize: 10,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            trailing,
          ],
        ),
      ),
    ),
  );
}

const List<double> _rates = <double>[.5, .75, 1, 1.25, 1.5, 2];
String _fitLabel(VideoFitMode mode) => switch (mode) {
  VideoFitMode.contain => '适应',
  VideoFitMode.cover => '填充',
  VideoFitMode.stretch => '拉伸',
};
String _trimRate(double rate) => rate == rate.roundToDouble()
    ? rate.toStringAsFixed(0)
    : rate.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
String _rateKey(double rate) => _trimRate(rate).replaceAll('.', '-');
