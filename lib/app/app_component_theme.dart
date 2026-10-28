/// 宿主 Material 控件的统一外观。
///
/// 职责：将按钮、输入、卡片、弹层和状态反馈连接到应用语义主题。
/// 注意：无 IO 或状态；正文阅读器继续持有独立主题和用户自定义。
part of 'app_theme.dart';

ThemeData _appComponentTheme(ThemeData theme, AppThemeTokens tokens) {
  final colors = theme.colorScheme;
  final text = theme.textTheme;
  const control = RoundedRectangleBorder(borderRadius: AppRadii.control);
  final card = RoundedRectangleBorder(
    borderRadius: AppRadii.card,
    side: BorderSide(color: tokens.divider),
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: AppRadii.control,
    borderSide: BorderSide(color: tokens.divider),
  );
  const buttonSize = Size(64, AppSpacing.minimumTouchTarget);
  return theme.copyWith(
    cardTheme: CardThemeData(
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: card,
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: buttonSize, shape: control, textStyle: text.labelLarge, elevation: 0),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: buttonSize,
        shape: control,
        textStyle: text.labelLarge,
        elevation: 0,
        backgroundColor: tokens.accentSoft,
        foregroundColor: colors.onPrimaryContainer,
        surfaceTintColor: Colors.transparent,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        shape: control,
        side: BorderSide(color: tokens.divider),
        foregroundColor: colors.onSurface,
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: buttonSize, shape: control, foregroundColor: tokens.focusRing, textStyle: text.labelLarge),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size.square(AppSpacing.minimumTouchTarget), shape: control, iconSize: 22),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: tokens.mutedSurface,
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: tokens.focusRing, width: 2)),
      errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: colors.error)),
      focusedErrorBorder: inputBorder.copyWith(borderSide: BorderSide(color: colors.error, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.regular),
      hintStyle: text.bodyLarge?.copyWith(color: tokens.mutedText),
      labelStyle: text.bodyMedium?.copyWith(color: tokens.mutedText),
      helperStyle: text.bodySmall?.copyWith(color: tokens.mutedText),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: card,
      constraints: const BoxConstraints(maxWidth: 560),
      titleTextStyle: text.titleLarge?.copyWith(color: colors.onSurface),
      contentTextStyle: text.bodyLarge?.copyWith(color: colors.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.surface,
      modalBackgroundColor: tokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      clipBehavior: Clip.antiAlias,
      dragHandleColor: tokens.mutedText.withValues(alpha: 0.4),
      dragHandleSize: const Size(36, 4),
      constraints: const BoxConstraints(maxWidth: 640),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      shape: card,
      elevation: 3,
      textStyle: text.bodyLarge?.copyWith(color: colors.onSurface),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tokens.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(card),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.mutedSurface,
      selectedColor: tokens.accentSoft,
      disabledColor: tokens.mutedSurface,
      side: BorderSide(color: tokens.divider),
      shape: control,
      labelStyle: text.bodyMedium?.copyWith(color: colors.onSurface),
      secondaryLabelStyle: text.bodyMedium?.copyWith(color: colors.onPrimaryContainer),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: tokens.mutedText,
      textColor: colors.onSurface,
      titleTextStyle: text.bodyLarge?.copyWith(color: colors.onSurface),
      subtitleTextStyle: text.bodyMedium?.copyWith(color: tokens.mutedText),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.unit),
      shape: control,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: tokens.accent,
      linearTrackColor: tokens.accentSoft,
      circularTrackColor: tokens.mutedSurface,
      linearMinHeight: AppSpacing.readingProgressHeight,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: tokens.focusRing,
      selectionColor: tokens.accent.withValues(alpha: 0.24),
      selectionHandleColor: tokens.focusRing,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: colors.inverseSurface, borderRadius: AppRadii.control),
      textStyle: text.bodyMedium?.copyWith(color: colors.onInverseSurface),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      shape: control,
      elevation: 0,
      actionTextColor: colors.inversePrimary,
      insetPadding: const EdgeInsets.all(AppSpacing.comfortable),
    ),
  );
}
