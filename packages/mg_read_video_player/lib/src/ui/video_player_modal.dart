/// Consistent video modal routes. Desktop uses a bounded floating panel; touch
/// uses a bottom sheet. Both retain system text scale, safe areas and scrolling.
/// Routes return choices only; playback and platform resources remain external.
library;

// Internal package presentation.
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'video_player_visuals.dart';

Future<T?> showVideoPlayerModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 620,
}) {
  Widget content(BuildContext context) => Theme(
    data: videoPlayerTheme(),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: builder(context),
    ),
  );
  if (videoPlayerUsesPointerControls(context)) {
    return showDialog<T>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      barrierColor: const Color(0x80000000),
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: MediaQuery.sizeOf(context).height * .86,
          ),
          child: content(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
        ? AnimationStyle.noAnimation
        : null,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x80000000),
    elevation: 0,
    useSafeArea: true,
    showDragHandle: false,
    isScrollControlled: true,
    constraints: BoxConstraints(maxWidth: maxWidth),
    builder: content,
  );
}
