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

/// 样式专项 token（v0.9.0 B1 按规范 §7 扩充）：4pt 网格 + 2pt micro。
/// 业务代码用语义档位取值，不再散落魔法数；档位变更必须先改规范再迁码。
abstract final class AppSpacing {
  /// 发丝间距：图标与文字微调、紧凑徽标内衬。
  static const double micro = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

/// 圆角档位（B1 扩充）：发丝 4、chip/ripple 6、卡片 8、大浮层 12、
/// composer 输入坞胶囊 22；全圆形状用 StadiumBorder/CircleBorder。
abstract final class AppRadius {
  static const double micro = 4;
  static const double small = 6;
  static const double card = 8;
  static const double large = 12;
  static const double pill = 22;
}

/// 高频固定尺寸 token，避免同类元素在不同屏幕各自漂移。
abstract final class AppSizes {
  static const double statusDot = 7;
  static const double avatarSmall = 34;
  static const double avatarMedium = 38;
  static const double avatarLarge = 42;

  /// 图标四档（规范 §5，2pt 步进）：行内 16、默认 18、工具栏 20、空态/强调 24。
  static const double iconSm = 16;
  static const double iconMd = 18;
  static const double iconLg = 20;
  static const double iconXl = 24;
}

/// 等宽字档（规范 §4.1）：代码、diff、路径、终端输出共用，业务代码禁止
/// 另写 fontSize: 13 monospace。唯一定义点在 token 定义文件。
abstract final class AppTypography {
  // 保持 inherit 默认（SelectableText 要求可继承样式带 textBaseline），
  // 颜色由消费方 copyWith 主题色。
  static const TextStyle mono = TextStyle(
    fontSize: 13,
    fontFamily: 'monospace',
  );
}

/// 透明度修饰 token（规范 §7）：模态压暗强度；基色始终来自 colorScheme.scrim。
abstract final class AppOpacity {
  static const double scrim = 0.24;
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
    // Dark uses the same layered neutrals as VS Code's workbench. Keeping the
    // roles explicit is important here: ColorScheme.fromSeed otherwise adds a
    // noticeable hue to container surfaces, which makes the UI read purple.
    final canvas = isDark ? const Color(0xff252526) : const Color(0xfff5f5f7);
    final surface = isDark ? const Color(0xff2d2d30) : const Color(0xffffffff);
    final surfaceRaised = isDark
        ? const Color(0xff37373d)
        : const Color(0xfffbfbfd);
    final border = isDark ? const Color(0xff5a5a5a) : const Color(0xffd2d2d7);
    final primaryText = isDark
        ? const Color(0xffd4d4d4)
        : const Color(0xff1d1d1f);
    final secondaryText = isDark
        ? const Color(0xffa6a6a6)
        : const Color(0xff6e6e73);
    final primary = _accentColor(accent, isDark);
    final onPrimary =
        ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
        ? Colors.white
        : const Color(0xff101010);
    final error = isDark ? const Color(0xfff48771) : const Color(0xffba1a1a);
    final errorContainer = isDark
        ? const Color(0xff4b2522)
        : const Color(0xffffdad6);
    final semantics = AppSemanticColors(
      surfaceRaised: surfaceRaised,
      border: border,
      textSecondary: secondaryText,
      success: isDark ? const Color(0xff89d185) : const Color(0xff16803c),
      warning: isDark ? const Color(0xffcca700) : const Color(0xffa85f00),
      info: isDark ? const Color(0xff3794ff) : const Color(0xff006fc9),
      neutral: isDark ? const Color(0xff858585) : secondaryText,
      diffAddition: isDark ? const Color(0xff203b2a) : const Color(0xffe2f5e8),
      diffDeletion: isDark ? const Color(0xff4b2522) : const Color(0xffffe9eb),
    );
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: onPrimary,
          secondary: semantics.success,
          onSecondary: isDark ? const Color(0xff252526) : Colors.white,
          secondaryContainer: isDark ? const Color(0xff2d4a36) : null,
          onSecondaryContainer: isDark ? const Color(0xffd6f5d8) : null,
          tertiary: semantics.warning,
          onTertiary: isDark
              ? const Color(0xff252526)
              : const Color(0xff1d1d1f),
          tertiaryContainer: isDark ? const Color(0xff4b3d00) : null,
          onTertiaryContainer: isDark ? const Color(0xfffff3b0) : null,
          surface: surface,
          onSurface: primaryText,
          surfaceContainerLowest: canvas,
          surfaceContainerLow: surface,
          surfaceContainer: surface,
          surfaceContainerHigh: surfaceRaised,
          surfaceContainerHighest: isDark
              ? const Color(0xff414147)
              : surfaceRaised,
          surfaceDim: isDark ? const Color(0xff202020) : null,
          surfaceBright: isDark ? const Color(0xff46464d) : null,
          onSurfaceVariant: secondaryText,
          outline: border,
          outlineVariant: isDark ? const Color(0xff3c3c3c) : null,
          error: error,
          onError: isDark ? const Color(0xff252526) : Colors.white,
          errorContainer: errorContainer,
          onErrorContainer: isDark
              ? const Color(0xffffd8d0)
              : const Color(0xff410002),
          primaryContainer: isDark ? _primaryContainer(accent) : null,
          onPrimaryContainer: isDark ? _onPrimaryContainer(accent) : null,
          inverseSurface: isDark ? const Color(0xffcccccc) : null,
          onInverseSurface: isDark ? const Color(0xff252526) : null,
          inversePrimary: isDark ? primary : null,
          surfaceTint: isDark ? Colors.transparent : null,
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
      isDark ? const Color(0xff007acc) : const Color(0xff0077ed),
    AppAccent.mint =>
      isDark ? const Color(0xff89d185) : const Color(0xff16803c),
    AppAccent.berry =>
      isDark ? const Color(0xfff14c4c) : const Color(0xffc72e50),
  };

  static Color _primaryContainer(AppAccent accent) => switch (accent) {
    AppAccent.ocean => const Color(0xff094771),
    AppAccent.mint => const Color(0xff294b2b),
    AppAccent.berry => const Color(0xff542626),
  };

  static Color _onPrimaryContainer(AppAccent accent) => switch (accent) {
    AppAccent.ocean => const Color(0xffd6ecff),
    AppAccent.mint => const Color(0xffd6f5d8),
    AppAccent.berry => const Color(0xffffd9d9),
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
