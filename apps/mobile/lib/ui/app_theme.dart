import 'package:flutter/material.dart';

import '../storage/theme_preference_store.dart';

/// 跨页面共用的语义色；业务代码不得直接依赖某个浅色或深色色值。
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.surfaceRaised,
    required this.border,
    required this.textSecondary,
    required this.success,
    required this.warning,
    required this.info,
    required this.neutral,
    required this.diffAddition,
    required this.diffDeletion,
  });

  final Color surfaceRaised;
  final Color border;
  final Color textSecondary;
  final Color success;
  final Color warning;
  final Color info;
  final Color neutral;
  final Color diffAddition;
  final Color diffDeletion;

  @override
  AppSemanticColors copyWith({
    Color? surfaceRaised,
    Color? border,
    Color? textSecondary,
    Color? success,
    Color? warning,
    Color? info,
    Color? neutral,
    Color? diffAddition,
    Color? diffDeletion,
  }) => AppSemanticColors(
    surfaceRaised: surfaceRaised ?? this.surfaceRaised,
    border: border ?? this.border,
    textSecondary: textSecondary ?? this.textSecondary,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    info: info ?? this.info,
    neutral: neutral ?? this.neutral,
    diffAddition: diffAddition ?? this.diffAddition,
    diffDeletion: diffDeletion ?? this.diffDeletion,
  );

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      border: Color.lerp(border, other.border, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      diffAddition: Color.lerp(diffAddition, other.diffAddition, t)!,
      diffDeletion: Color.lerp(diffDeletion, other.diffDeletion, t)!,
    );
  }
}

extension AppThemeContext on BuildContext {
  AppSemanticColors get appColors {
    final theme = Theme.of(this);
    return theme.extension<AppSemanticColors>() ??
        AppSemanticColors(
          surfaceRaised: theme.colorScheme.surfaceContainerHigh,
          border: theme.dividerColor,
          textSecondary: theme.colorScheme.onSurfaceVariant,
          success: theme.colorScheme.secondary,
          warning: theme.colorScheme.tertiary,
          info: theme.colorScheme.primary,
          neutral: theme.colorScheme.onSurfaceVariant,
          diffAddition: theme.colorScheme.secondaryContainer,
          diffDeletion: theme.colorScheme.errorContainer,
        );
  }
}

/// 样式专项 token：4pt 网格间距。业务代码用语义档位取值，不再散落魔法数。
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

/// 圆角三档：小控件（chip/ripple/tooltip）6、卡片 8、胶囊（composer 输入坞）22。
abstract final class AppRadius {
  static const double small = 6;
  static const double card = 8;
  static const double pill = 22;
}

/// 高频固定尺寸 token，避免同类元素在不同屏幕各自漂移。
abstract final class AppSizes {
  static const double statusDot = 7;
  static const double avatarSmall = 34;
  static const double avatarMedium = 38;
  static const double avatarLarge = 42;
}

/// 阴影 token：目前仅 composer 胶囊一处投影，先收口避免第二处硬编码扩散。
abstract final class AppShadows {
  static const List<BoxShadow> composerPill = [
    BoxShadow(color: Color(0x12000000), blurRadius: 12, offset: Offset(0, 3)),
  ];
}

/// P1 的主题入口：系统字体、内容优先层级和紧凑 8px 圆角，不复制 Apple 品牌资产。
abstract final class AppTheme {
  static ThemeData light(AppAccent accent) =>
      _build(brightness: Brightness.light, accent: accent);

  static ThemeData dark(AppAccent accent) =>
      _build(brightness: Brightness.dark, accent: accent);

  static ThemeData _build({
    required Brightness brightness,
    required AppAccent accent,
  }) {
    final isDark = brightness == Brightness.dark;
    final canvas = isDark ? const Color(0xff000000) : const Color(0xfff5f5f7);
    final surface = isDark ? const Color(0xff1d1d1f) : const Color(0xffffffff);
    final surfaceRaised = isDark
        ? const Color(0xff2c2c2e)
        : const Color(0xfffbfbfd);
    final border = isDark ? const Color(0xff424245) : const Color(0xffd2d2d7);
    final primaryText = isDark
        ? const Color(0xfff5f5f7)
        : const Color(0xff1d1d1f);
    final secondaryText = isDark
        ? const Color(0xffa1a1a6)
        : const Color(0xff6e6e73);
    final primary = _accentColor(accent, isDark);
    final onPrimary =
        ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
        ? Colors.white
        : const Color(0xff101010);
    final error = isDark ? const Color(0xffffb4ab) : const Color(0xffba1a1a);
    final errorContainer = isDark
        ? const Color(0xff5b1f25)
        : const Color(0xffffdad6);
    final semantics = AppSemanticColors(
      surfaceRaised: surfaceRaised,
      border: border,
      textSecondary: secondaryText,
      success: isDark ? const Color(0xff75d99b) : const Color(0xff16803c),
      warning: isDark ? const Color(0xffffc05c) : const Color(0xffa85f00),
      info: isDark ? const Color(0xff64b5ff) : const Color(0xff006fc9),
      neutral: secondaryText,
      diffAddition: isDark ? const Color(0xff193c2c) : const Color(0xffe2f5e8),
      diffDeletion: isDark ? const Color(0xff49262a) : const Color(0xffffe9eb),
    );
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: onPrimary,
          secondary: semantics.success,
          onSecondary: isDark ? const Color(0xff062c18) : Colors.white,
          tertiary: semantics.warning,
          onTertiary: const Color(0xff1d1d1f),
          surface: surface,
          onSurface: primaryText,
          surfaceContainerLowest: canvas,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: surfaceRaised,
          surfaceContainerHighest: surfaceRaised,
          outline: border,
          error: error,
          onError: isDark ? const Color(0xff690005) : Colors.white,
          errorContainer: errorContainer,
          onErrorContainer: isDark
              ? const Color(0xffffdad6)
              : const Color(0xff410002),
        );
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
    );
    final textTheme = TextTheme(
      headlineSmall: TextStyle(
        color: primaryText,
        fontSize: 26,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleLarge: TextStyle(
        color: primaryText,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        color: primaryText,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      // 此前未定义：调用点静默回落 Material 默认（11px/w500/letterSpacing 0.5），
      // 补齐后全部 labelSmall 调用点一次性回到应用字阶。
      titleSmall: TextStyle(
        color: primaryText,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelSmall: TextStyle(
        color: secondaryText,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
      ),
      bodyLarge: TextStyle(color: primaryText, fontSize: 17, letterSpacing: 0),
      bodyMedium: TextStyle(
        color: secondaryText,
        fontSize: 14,
        letterSpacing: 0,
      ),
      bodySmall: TextStyle(
        color: secondaryText,
        fontSize: 12,
        letterSpacing: 0,
      ),
      labelLarge: TextStyle(
        color: primaryText,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      labelMedium: TextStyle(
        color: secondaryText,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      dividerColor: border,
      extensions: [semantics],
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: primaryText,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        toolbarHeight: 60,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      dividerTheme: DividerThemeData(color: border, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        labelStyle: TextStyle(color: secondaryText),
        hintStyle: TextStyle(color: secondaryText),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: error, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          // Size.fromHeight creates an infinite width. That is valid only in
          // a bounded vertical layout and crashes buttons placed in a Row.
          minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
          backgroundColor: WidgetStatePropertyAll(primary),
          foregroundColor: WidgetStatePropertyAll(onPrimary),
          shape: const WidgetStatePropertyAll(shape),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
          foregroundColor: WidgetStatePropertyAll(primaryText),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          shape: const WidgetStatePropertyAll(shape),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(primary),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: secondaryText,
        textColor: primaryText,
        contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
        minVerticalPadding: 10,
        minLeadingWidth: 32,
        horizontalTitleGap: 12,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(primaryText),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(primaryText),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
          shape: const WidgetStatePropertyAll(shape),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceRaised,
        contentTextStyle: TextStyle(color: primaryText),
        shape: shape,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceRaised,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: primaryText),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: primary,
        selectionColor: primary.withValues(alpha: 0.24),
        selectionHandleColor: primary,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: _ReducedMotionPageTransitionsBuilder(),
          TargetPlatform.iOS: _ReducedMotionPageTransitionsBuilder(),
          TargetPlatform.macOS: _ReducedMotionPageTransitionsBuilder(),
          TargetPlatform.windows: _ReducedMotionPageTransitionsBuilder(),
          TargetPlatform.linux: _ReducedMotionPageTransitionsBuilder(),
          TargetPlatform.fuchsia: _ReducedMotionPageTransitionsBuilder(),
        },
      ),
    );
  }

  static Color _accentColor(AppAccent accent, bool isDark) => switch (accent) {
    AppAccent.ocean =>
      isDark ? const Color(0xff0a84ff) : const Color(0xff0077ed),
    AppAccent.mint =>
      isDark ? const Color(0xff34c759) : const Color(0xff16803c),
    AppAccent.berry =>
      isDark ? const Color(0xffff6482) : const Color(0xffc72e50),
  };
}

/// 当系统请求减少动态效果时，路由直接切换内容，避免视觉动画成为操作负担。
class _ReducedMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const _ReducedMotionPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return child;
    return const FadeUpwardsPageTransitionsBuilder().buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
