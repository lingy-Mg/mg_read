import 'package:mg_read_motion/mg_read_motion.dart';
import 'package:flutter/material.dart';

import '../reader_strings.dart';
import '../reader_theme.dart';
import 'reader_settings_controls.dart';
import 'reader_settings_tokens.dart';

/// Compact font-size control shared by the main settings page and typography
/// subpage.
///
/// The value in the middle is deliberately display-only. The quick actions
/// change the size in whole-pixel steps, while the subpage can additionally
/// expose the continuous progress bar for precise adjustment.
class ReaderSettingsFontSizeControl extends StatelessWidget {
  const ReaderSettingsFontSizeControl({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.palette,
    required this.onDecrease,
    required this.onIncrease,
    this.showProgress = false,
    this.onProgressChanged,
    this.onProgressChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final ReaderPalette palette;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final bool showProgress;
  final ValueChanged<double>? onProgressChanged;
  final ValueChanged<double>? onProgressChangeEnd;

  @override
  Widget build(BuildContext context) {
    final bool canDecrease = value > min;
    final bool canIncrease = value < max;
    return Semantics(
      container: true,
      label: '${ReaderStrings.fontSize} ${value.round()}',
      child: ReaderSettingsCapsule(
        palette: palette,
        padding: EdgeInsets.symmetric(horizontal: showProgress ? 2 : 4),
        child: Row(
          children: <Widget>[
            _buildAction(
              key: const ValueKey<String>('reader-settings-font-size-decrease'),
              tooltip: ReaderStrings.decreaseFontSize,
              icon: Icons.remove_rounded,
              onPressed: canDecrease ? onDecrease : null,
            ),
            if (showProgress)
              Expanded(
                child: MotionSlider(
                  value: value,
                  min: min,
                  max: max,
                  label: value.round().toString(),
                  semanticFormatterCallback: (double nextValue) =>
                      '${ReaderStrings.fontSize} ${nextValue.round()}',
                  onChanged: onProgressChanged,
                  onChangeEnd: onProgressChangeEnd,
                ),
              )
            else
              const Spacer(),
            SizedBox(
              key: const ValueKey<String>('reader-settings-font-size-value'),
              width: 34,
              child: Text(
                value.round().toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (!showProgress) const Spacer(),
            _buildAction(
              key: const ValueKey<String>('reader-settings-font-size-increase'),
              tooltip: ReaderStrings.increaseFontSize,
              icon: Icons.add_rounded,
              onPressed: canIncrease ? onIncrease : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAction({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 32,
      height: ReaderSettingsTokens.controlHeight,
      child: MotionIconButtonSurface(
        child: IconButton(
          key: key,
          tooltip: tooltip,
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: Icon(icon),
        ),
      ),
    );
  }
}
