import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';

void main() {
  test('exposes the compact semantic typography scale globally', () {
    final textTheme = AppTheme.light().textTheme;

    expect(textTheme.displaySmall?.fontSize, AppTypography.display);
    expect(textTheme.titleLarge?.fontSize, AppTypography.sectionTitle);
    expect(textTheme.titleMedium?.fontSize, AppTypography.itemTitle);
    expect(textTheme.bodyLarge?.fontSize, AppTypography.body);
    expect(textTheme.bodyMedium?.fontSize, AppTypography.secondary);
    expect(textTheme.bodySmall?.fontSize, AppTypography.caption);
    expect(textTheme.labelLarge?.fontSize, AppTypography.action);
  });
}
