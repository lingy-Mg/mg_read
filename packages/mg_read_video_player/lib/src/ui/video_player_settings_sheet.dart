/// Player-styled presentation of settings that do not belong beside progress.
///
/// Responsibilities:
/// - Keep episode navigation, repeat, rate and fit controls in one visual panel.
/// - Reuse the video glass treatment in portrait and fullscreen landscapes.
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

Future<void> showVideoPlayerSettingsSheet({
  required BuildContext context,
  required VideoPlayerSnapshot snapshot,
  required Future<void> Function(double) onRate,
  required Future<void> Function() onFit,
  required Future<void> Function() onPreviousEpisode,
  required Future<void> Function() onNextEpisode,
  required Future<void> Function(bool) onAutoAdvance,
}) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0xA6000000),
  elevation: 0,
  useSafeArea: true,
  showDragHandle: false,
  constraints: const BoxConstraints(maxWidth: double.infinity),
  builder: (_) => Theme(
    data: videoPlayerTheme(),
    child: _VideoPlayerSettingsSheet(
      snapshot: snapshot,
      onRate: onRate,
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
    required this.onFit,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onAutoAdvance,
  });

  final VideoPlayerSnapshot snapshot;
  final Future<void> Function(double) onRate;
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    return VideoPlayerGlassPanel(
      key: const Key('video-player-settings-sheet'),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      showBorder: false,
      blurSigma: 22,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.size.height * (landscape ? .86 : .72),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(18, 10, 18, 16 + media.padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Align(
                child: SizedBox(
                  width: 30,
                  height: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x8CFFFFFF),
                      borderRadius: BorderRadius.all(Radius.circular(99)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.tune_rounded,
                    color: videoPlayerAccent,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '播放设置',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: videoPlayerForeground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _SettingsSectionLabel('选集切换'),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _EpisodeAction(
                      key: const Key('video-player-previous-episode'),
                      icon: Icons.skip_previous_rounded,
                      label: '上一集',
                      enabled:
                          widget.snapshot.hasPreviousEpisode ||
                          widget.snapshot.position >=
                              const Duration(seconds: 5),
                      onPressed: widget.onPreviousEpisode,
                    ),
                  ),
                  const SizedBox(width: 10),
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
              const SizedBox(height: 18),
              const _SettingsSectionLabel('播放方式'),
              const SizedBox(height: 8),
              _SettingsRow(
                icon: Icons.repeat_rounded,
                label: '自动连播',
                detail: _autoAdvance ? '当前开启' : '当前关闭',
                trailing: Switch.adaptive(
                  key: const Key('video-player-auto-advance'),
                  value: _autoAdvance,
                  activeTrackColor: videoPlayerAccent,
                  onChanged: _setAutoAdvance,
                ),
              ),
              const SizedBox(height: 12),
              _SettingsRow(
                icon: Icons.aspect_ratio_rounded,
                label: '画面比例',
                detail: _fitLabel(_fitMode),
                detailHint: _fitMode == VideoFitMode.contain ? '默认' : null,
                trailing: TextButton(
                  key: const Key('video-player-fit'),
                  onPressed: _cycleFitMode,
                  style: TextButton.styleFrom(
                    foregroundColor: videoPlayerAccent,
                  ),
                  child: const Text('切换'),
                ),
              ),
              const SizedBox(height: 18),
              const _SettingsSectionLabel('播放速度'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final rate in _rates)
                    ChoiceChip(
                      key: Key('video-player-rate-${_rateKey(rate)}'),
                      label: Text('${_trimRate(rate)}×'),
                      selected: _rate == rate,
                      showCheckmark: false,
                      selectedColor: videoPlayerAccent,
                      backgroundColor: const Color(0x1AFFFFFF),
                      side: BorderSide.none,
                      labelStyle: TextStyle(
                        color: _rate == rate
                            ? const Color(0xFF111214)
                            : videoPlayerForeground,
                        fontWeight: FontWeight.w600,
                      ),
                      onSelected: (_) => _setRate(rate),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SettingsSectionLabel extends StatelessWidget {
  const _SettingsSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: videoPlayerSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
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
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: enabled ? onPressed : null,
    style: FilledButton.styleFrom(
      foregroundColor: enabled
          ? videoPlayerForeground
          : videoPlayerSecondary.withValues(alpha: .45),
      backgroundColor: const Color(0x1AFFFFFF),
      disabledBackgroundColor: const Color(0x0DFFFFFF),
      padding: const EdgeInsets.symmetric(vertical: 12),
    ),
    icon: Icon(icon, size: 20),
    label: Text(label),
  );
}

final class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.trailing,
    this.detailHint,
  });

  final IconData icon;
  final String label;
  final String detail;
  final Widget trailing;
  final String? detailHint;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0x14000000),
      borderRadius: BorderRadius.all(Radius.circular(12)),
      border: Border.fromBorderSide(BorderSide(color: Color(0x1FFFFFFF))),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: <Widget>[
          Icon(icon, color: videoPlayerSecondary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: const TextStyle(
                    color: videoPlayerForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text.rich(
                  key: detailHint == null
                      ? null
                      : const Key('video-player-fit-default-hint'),
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(text: detail),
                      if (detailHint case final hint?)
                        TextSpan(
                          text: '  $hint',
                          style: TextStyle(
                            color: videoPlayerSecondary.withValues(alpha: .68),
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                  style: const TextStyle(
                    color: videoPlayerSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          trailing,
        ],
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
