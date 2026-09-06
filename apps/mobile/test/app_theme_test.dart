import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:agent_sessions_mobile/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('深色主题使用 VS Code 工作台中性色层级', () {
    final theme = AppTheme.dark(AppAccent.ocean);
    final scheme = theme.colorScheme;

    expect(theme.scaffoldBackgroundColor, const Color(0xff252526));
    expect(scheme.surface, const Color(0xff2d2d30));
    expect(scheme.surfaceContainerHigh, const Color(0xff37373d));
    expect(scheme.primary, const Color(0xff007acc));
    expect(scheme.onSurface, const Color(0xffd4d4d4));
    expect(scheme.onSurfaceVariant, const Color(0xffa6a6a6));
  });

  test('深色 accent 使用对应的 VS Code 语义色', () {
    expect(
      AppTheme.dark(AppAccent.mint).colorScheme.primary,
      const Color(0xff89d185),
    );
    expect(
      AppTheme.dark(AppAccent.berry).colorScheme.primary,
      const Color(0xfff14c4c),
    );
  });

  // ─── v0.9.0 B1：token 扩充档位与亮暗 scrim 断言（V090-11）───

  test('B1 token 档位与规范 §7 一致', () {
    // 间距：4pt 网格 + 2pt micro。
    expect(AppSpacing.micro, 2);
    expect(AppSpacing.xs, 4);
    expect(AppSpacing.sm, 8);
    expect(AppSpacing.md, 12);
    expect(AppSpacing.lg, 16);
    expect(AppSpacing.xl, 20);
    expect(AppSpacing.xxl, 24);
    // 圆角五档。
    expect(AppRadius.micro, 4);
    expect(AppRadius.small, 6);
    expect(AppRadius.card, 8);
    expect(AppRadius.large, 12);
    expect(AppRadius.pill, 22);
    // 图标四档。
    expect(AppSizes.iconSm, 16);
    expect(AppSizes.iconMd, 18);
    expect(AppSizes.iconLg, 20);
    expect(AppSizes.iconXl, 24);
    // 等宽字档与 scrim 透明度。
    expect(AppTypography.mono.fontSize, 13);
    expect(AppTypography.mono.fontFamily, 'monospace');
    expect(AppOpacity.scrim, 0.24);
  });

  test('B1 亮/暗两套主题均提供语义 scrim', () {
    for (final theme in [AppTheme.light(AppAccent.ocean), AppTheme.dark(AppAccent.ocean)]) {
      expect(theme.colorScheme.scrim, isNot(const Color(0x00000000)));
      // ColorScheme.scrim 默认为不透明黑；亮暗共用，遮罩强度由 AppOpacity.scrim 修饰。
      expect(theme.colorScheme.scrim, const Color(0xff000000));
    }
  });

  test('B1 等宽字档在深色背景以主题色消费（inherit 关闭不串色）', () {
    // AppTypography.mono 是独立档：业务代码 copyWith 颜色后消费，
    // token 本身不带颜色，避免亮暗串色。
    expect(AppTypography.mono.color, isNull);
  });
}
