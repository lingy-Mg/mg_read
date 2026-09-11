/// 小说与漫画阅读器共用的顶部来源副标题。
///
/// 职责：
/// - 统一来源名称、来源链接、缺省文案和链接语义的布局。
/// - 由调用方提供阅读器类别对应的视觉样式和外部打开动作。
///
/// 注意：
/// - 本组件不直接打开 URL，也不处理失败；平台动作和错误上报仍由各阅读会话持有。
/// - 小说与漫画只复用结构和交互语义，不共享各自的顶栏颜色。
library;

import 'package:flutter/material.dart';

import 'reader_accessible_tooltip.dart';
import 'reader_strings.dart';
import 'reader_theme.dart';

@immutable
class ReaderSourceStripStyle {
  const ReaderSourceStripStyle({
    required this.surface,
    required this.divider,
    required this.sourceText,
    required this.inactiveText,
    required this.linkText,
    required this.linkAccent,
  });

  factory ReaderSourceStripStyle.text(ReaderPalette palette) =>
      ReaderSourceStripStyle(
        surface: palette.panel.withValues(alpha: .76),
        divider: palette.divider,
        sourceText: palette.secondaryText.withValues(alpha: .78),
        inactiveText: palette.secondaryText.withValues(alpha: .78),
        linkText: palette.text.withValues(alpha: .78),
        linkAccent: palette.accent.withValues(alpha: .82),
      );

  factory ReaderSourceStripStyle.comic(ReaderPalette palette) =>
      ReaderSourceStripStyle(
        surface: const Color(0xD917191B),
        divider: const Color(0x243A3D40),
        sourceText: palette.secondaryText.withValues(alpha: .92),
        inactiveText: palette.secondaryText.withValues(alpha: .82),
        linkText: palette.text.withValues(alpha: .90),
        linkAccent: palette.accent,
      );

  final Color surface;
  final Color divider;
  final Color sourceText;
  final Color inactiveText;
  final Color linkText;
  final Color linkAccent;
}

class ReaderSourceStrip extends StatelessWidget {
  const ReaderSourceStrip({
    required this.sourceName,
    required this.sourceUrl,
    required this.sourceUri,
    required this.style,
    this.onOpenSource,
    this.sourceNameKey,
    this.sourceUrlRegionKey,
    super.key,
  });

  final String? sourceName;
  final String? sourceUrl;
  final Uri? sourceUri;
  final ReaderSourceStripStyle style;
  final VoidCallback? onOpenSource;
  final Key? sourceNameKey;
  final Key? sourceUrlRegionKey;

  @override
  Widget build(BuildContext context) {
    final String normalizedName = sourceName?.trim() ?? '';
    final bool linkEnabled = sourceUri != null && onOpenSource != null;
    final Widget label = Row(
      children: <Widget>[
        Icon(
          Icons.open_in_new_rounded,
          size: 14,
          color: linkEnabled ? style.linkAccent : style.inactiveText,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            sourceUrl ?? ReaderStrings.sourceUrlUnavailable,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: linkEnabled ? style.linkText : style.inactiveText,
              fontSize: 11,
              decoration: linkEnabled ? TextDecoration.underline : null,
              decorationColor: style.linkAccent,
            ),
          ),
        ),
      ],
    );
    final Widget urlAction = linkEnabled
        ? ReaderAccessibleTooltip(
            label: '${ReaderStrings.openSourceUrl}: $sourceUrl',
            tooltipMessage: sourceUrl,
            link: true,
            onTap: onOpenSource!,
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: onOpenSource,
              child: SizedBox(height: 22, child: label),
            ),
          )
        : label;

    return Material(
      color: style.surface,
      elevation: 0,
      child: Container(
        height: 28,
        padding: const EdgeInsets.only(left: 56, right: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: style.divider)),
        ),
        child: SizedBox(
          height: 22,
          child: Row(
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 104),
                child: Text(
                  normalizedName.isEmpty
                      ? ReaderStrings.sourceUnavailable
                      : normalizedName,
                  key: sourceNameKey,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: style.sourceText, fontSize: 11),
                ),
              ),
              const SizedBox(width: 8),
              Container(width: 1, height: 14, color: style.divider),
              const SizedBox(width: 8),
              Expanded(key: sourceUrlRegionKey, child: urlAction),
            ],
          ),
        ),
      ),
    );
  }
}
