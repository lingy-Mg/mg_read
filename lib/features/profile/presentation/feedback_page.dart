/// 意见反馈页面。
///
/// 职责：
/// - 管理本地表单输入、焦点与轻量交互反馈。
/// - 以统一的二级页标题栏承载可滚动的反馈内容。
///
/// 注意：
/// - 不在此页面上传文件、发起网络请求或持久化用户输入。
/// - 标题栏必须固定在内容滚动区域之外，并由安全区和共享页面壳统一定位。
///
/// TODO:
/// - 无。
library;

import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/features/profile/presentation/widgets/feedback_thanks_banner.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({required this.onBackRequested, required this.onDestinationRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();
  final FocusNode _contentFocusNode = FocusNode();
  final FocusNode _contactFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  _FeedbackType _selectedType = _FeedbackType.suggestion;

  @override
  void initState() {
    super.initState();
    _contentController.addListener(_handleContentChanged);
  }

  @override
  void dispose() {
    _contentController
      ..removeListener(_handleContentChanged)
      ..dispose();
    _contactController.dispose();
    _contentFocusNode.dispose();
    _contactFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleContentChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              ProfileDetailTopBar(title: '意见反馈', onBack: widget.onBackRequested),
              Expanded(
                child: ListView(
                  key: const Key('feedback-page-content'),
                  controller: _scrollController,
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: AppDetailMetrics.horizontalPadding),
                      child: FeedbackThanksBanner(),
                    ),
                    const SizedBox(height: AppDetailMetrics.feedbackCardTopGap),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppDetailMetrics.horizontalPadding),
                      child: _FeedbackFormCard(
                        contentController: _contentController,
                        contactController: _contactController,
                        contentFocusNode: _contentFocusNode,
                        contactFocusNode: _contactFocusNode,
                        selectedType: _selectedType,
                        contentLength: _contentController.text.characters.length,
                        onTypeSelected: (_FeedbackType value) {
                          setState(() {
                            _selectedType = value;
                          });
                        },
                        onAddImage: () => _showMessage('截图选择尚未接入，当前不会访问本地文件。'),
                        onSubmit: _submit,
                      ),
                    ),
                    const SizedBox(height: 9),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    if (_contentController.text.trim().isEmpty) {
      _showMessage('请先填写反馈内容。');
      return;
    }
    _showMessage('反馈已保留在当前页面，提交服务尚未接入。');
  }

  void _showMessage(String message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _FeedbackFormCard extends StatelessWidget {
  const _FeedbackFormCard({
    required this.contentController,
    required this.contactController,
    required this.contentFocusNode,
    required this.contactFocusNode,
    required this.selectedType,
    required this.contentLength,
    required this.onTypeSelected,
    required this.onAddImage,
    required this.onSubmit,
  });

  final TextEditingController contentController;
  final TextEditingController contactController;
  final FocusNode contentFocusNode;
  final FocusNode contactFocusNode;
  final _FeedbackType selectedType;
  final int contentLength;
  final ValueChanged<_FeedbackType> onTypeSelected;
  final VoidCallback onAddImage;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      key: const Key('feedback-form-card'),
      height: AppDetailMetrics.feedbackCardHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.detailCard,
          border: Border.all(color: tokens.mutedText.withValues(alpha: 0.2), width: 0.8),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppDetailMetrics.feedbackCardPadding, 16, AppDetailMetrics.feedbackCardPadding, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _FeedbackSectionLabel(title: '反馈类型'),
              const SizedBox(height: 8),
              _FeedbackTypeSelector(selectedType: selectedType, onSelected: onTypeSelected),
              const SizedBox(height: 22),
              const _FeedbackSectionLabel(title: '反馈内容'),
              const SizedBox(height: 6),
              _FeedbackContentEditor(controller: contentController, focusNode: contentFocusNode, contentLength: contentLength),
              const SizedBox(height: 16),
              const _FeedbackSectionLabel(title: '上传截图', optional: true),
              const SizedBox(height: 8),
              _FeedbackImageTile(onPressed: onAddImage),
              const SizedBox(height: 15),
              const _FeedbackSectionLabel(title: '联系方式', optional: true),
              const SizedBox(height: 8),
              _FeedbackContactField(controller: contactController, focusNode: contactFocusNode),
              const SizedBox(height: 5),
              const _FeedbackHelperText(),
              const SizedBox(height: 13),
              _FeedbackSubmitButton(onPressed: onSubmit),
              const SizedBox(height: 8),
              const _FeedbackPrivacyNotice(),
            ],
          ),
        ),
      ),
    );
  }
}

enum _FeedbackType { suggestion, problem, plugin, other }

class _FeedbackTypeSelector extends StatelessWidget {
  const _FeedbackTypeSelector({required this.selectedType, required this.onSelected});

  final _FeedbackType selectedType;
  final ValueChanged<_FeedbackType> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppDetailMetrics.feedbackTypeHeight,
      child: Row(
        children: <Widget>[
          Expanded(
            child: _FeedbackTypeButton(
              type: _FeedbackType.suggestion,
              label: '功能建议',
              icon: Icons.rate_review_outlined,
              selected: selectedType == _FeedbackType.suggestion,
              onPressed: onSelected,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _FeedbackTypeButton(
              type: _FeedbackType.problem,
              label: '问题反馈',
              icon: Icons.warning_amber_rounded,
              selected: selectedType == _FeedbackType.problem,
              onPressed: onSelected,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _FeedbackTypeButton(
              type: _FeedbackType.plugin,
              label: '插件相关',
              icon: Icons.extension_outlined,
              selected: selectedType == _FeedbackType.plugin,
              onPressed: onSelected,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 56,
            child: _FeedbackTypeButton(
              type: _FeedbackType.other,
              label: '其他',
              icon: Icons.grid_view_rounded,
              selected: selectedType == _FeedbackType.other,
              onPressed: onSelected,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedbackTypeButton extends StatelessWidget {
  const _FeedbackTypeButton({required this.type, required this.label, required this.icon, required this.selected, required this.onPressed});

  final _FeedbackType type;
  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<_FeedbackType> onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color foreground = selected ? tokens.warning : tokens.mutedText;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? tokens.accentSoft.withValues(alpha: 0.72) : tokens.mutedSurface.withValues(alpha: 0.58),
            borderRadius: AppRadii.detailControl,
            border: Border.all(color: selected ? tokens.warning : tokens.mutedText.withValues(alpha: 0.17), width: selected ? 0.9 : 0.7),
          ),
          child: InkWell(
            key: ValueKey<String>('feedback-type-${type.name}'),
            onTap: () => onPressed(type),
            borderRadius: AppRadii.detailControl,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, size: 16, color: foreground),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      height: 1,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackSectionLabel extends StatelessWidget {
  const _FeedbackSectionLabel({required this.title, this.optional = false});

  final String title;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 22,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            children: <InlineSpan>[
              TextSpan(
                text: title,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  letterSpacing: 0,
                ),
              ),
              if (optional)
                TextSpan(
                  text: '（选填）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                    letterSpacing: 0,
                  ),
                ),
            ],
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}

class _FeedbackContentEditor extends StatelessWidget {
  const _FeedbackContentEditor({required this.controller, required this.focusNode, required this.contentLength});

  final TextEditingController controller;
  final FocusNode focusNode;
  final int contentLength;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      key: const Key('feedback-content-editor'),
      height: AppDetailMetrics.feedbackEditorHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.detailControl,
          border: Border.all(color: tokens.mutedText.withValues(alpha: 0.23), width: 0.8),
        ),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 11, 12, 30),
                child: TextField(
                  key: const Key('feedback-content-field'),
                  controller: controller,
                  focusNode: focusNode,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  cursorColor: tokens.warning,
                  inputFormatters: <TextInputFormatter>[LengthLimitingTextInputFormatter(500)],
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    letterSpacing: 0,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    hintText: '请详细描述您的建议或遇到的问题…\n我们会认真阅读并尽快回复您。',
                    hintMaxLines: 2,
                    hintStyle: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.mutedText.withValues(alpha: 0.78),
                      fontWeight: FontWeight.w400,
                      height: 1.5,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 11,
              bottom: 9,
              child: Text(
                '$contentLength/500',
                key: const Key('feedback-character-count'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: tokens.mutedText,
                  fontWeight: FontWeight.w400,
                  height: 1,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedbackImageTile extends StatelessWidget {
  const _FeedbackImageTile({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      key: const Key('feedback-image-tile'),
      width: AppDetailMetrics.feedbackUploadTileExtent,
      height: AppDetailMetrics.feedbackUploadTileExtent,
      child: CustomPaint(
        painter: _DashedRoundedBorderPainter(color: tokens.mutedText.withValues(alpha: 0.3)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('feedback-add-image'),
            onTap: onPressed,
            borderRadius: AppRadii.detailControl,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.add_photo_alternate_outlined, color: tokens.mutedText, size: 31),
                const SizedBox(height: 7),
                Text(
                  '添加图片',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.15,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '（最多5张）',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.15,
                    letterSpacing: 0,
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

class _DashedRoundedBorderPainter extends CustomPainter {
  const _DashedRoundedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Path borderPath = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)));
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    for (final PathMetric metric in borderPath.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 5), paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedBorderPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _FeedbackContactField extends StatelessWidget {
  const _FeedbackContactField({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      key: const Key('feedback-contact-field-container'),
      height: AppDetailMetrics.feedbackContactHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.detailControl,
          border: Border.all(color: tokens.mutedText.withValues(alpha: 0.23), width: 0.8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            key: const Key('feedback-contact-field'),
            controller: controller,
            focusNode: focusNode,
            keyboardType: TextInputType.emailAddress,
            cursorColor: tokens.warning,
            maxLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w400,
              height: 1.25,
              letterSpacing: 0,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              hintText: '请留下您的邮箱或手机号，方便我们联系您',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.mutedText.withValues(alpha: 0.72),
                fontWeight: FontWeight.w400,
                height: 1.2,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackHelperText extends StatelessWidget {
  const _FeedbackHelperText();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 18,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '仅用于反馈回复，不会对外公开',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.2, letterSpacing: 0),
        ),
      ),
    );
  }
}

class _FeedbackSubmitButton extends StatelessWidget {
  const _FeedbackSubmitButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      key: const Key('feedback-submit-button'),
      width: double.infinity,
      height: AppDetailMetrics.feedbackSubmitHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: <Color>[Color.lerp(tokens.warning, tokens.surface, 0.075)!, Color.lerp(tokens.warning, tokens.surface, 0.055)!],
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('feedback-submit'),
            onTap: onPressed,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Center(
              child: Text(
                '提交反馈',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackPrivacyNotice extends StatelessWidget {
  const _FeedbackPrivacyNotice();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 18,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.security_rounded, color: tokens.mutedText, size: 14),
          const SizedBox(width: 7),
          Text(
            '我们会严格保护您的隐私信息',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w400, height: 1.2, letterSpacing: 0),
          ),
        ],
      ),
    );
  }
}
