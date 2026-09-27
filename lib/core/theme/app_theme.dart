import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app chrome, styled after Omarchy's shell
/// (https://github.com/basecamp/omarchy shell/Commons/Style.qml): flat
/// surfaces from the theme background, 1px borders in the muted colour,
/// near-square corners, the accent for selection and focus, and the
/// monospace font for headings and labels. No gradients, glows or shadows.
class AppTheme {
  const AppTheme._();

  /// Corner radius of cards, fields, buttons and menus. Omarchy's shell
  /// and Hyprland windows are square (cornerRadius 0, rounding 0); 3px
  /// keeps that look on a phone while taking the edge off touch targets.
  static const double radius = 3;

  /// Sheets and dialogs: Omarchy's popped windows use a slightly larger
  /// rounding than tiles.
  static const double radiusLarge = 6;

  /// The font of headings and labels: Omarchy's monospace.
  static final String monoFontFamily =
      TerminalFontOption.jetBrainsMonoNerdFont.fontFamily;

  static BorderRadius get borderRadius => BorderRadius.circular(radius);

  static SystemUiOverlayStyle systemUiOverlayStyle(Brightness brightness) {
    final iconBrightness = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return (brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark)
        .copyWith(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: iconBrightness,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: iconBrightness,
          systemNavigationBarContrastEnforced: false,
        );
  }

  /// Builds the theme for [palette]. The palette is dark or light itself;
  /// [brightness] only names the MaterialApp slot being filled.
  static ThemeData build({
    required Brightness brightness,
    required AppPalette palette,
  }) {
    final themeBrightness = palette.brightness;
    final canvas = palette.canvas;
    final panel = palette.panel;
    final panelElevated = palette.panelElevated;
    final hairline = palette.hairline;
    final border = palette.border;
    final foreground = palette.foreground;
    final muted = palette.mutedForeground;
    final subtle = palette.subtleForeground;
    final accent = palette.accent;
    final onAccent = palette.onAccent;
    final selected = palette.selectedFill;
    final square = RoundedRectangleBorder(borderRadius: borderRadius);
    RoundedRectangleBorder outlined(Color color, {double radius = radius}) =>
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: color),
        );

    final base = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: themeBrightness,
    );
    final colorScheme = base.copyWith(
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: selected,
      onPrimaryContainer: foreground,
      secondary: accent,
      onSecondary: onAccent,
      secondaryContainer: selected,
      onSecondaryContainer: foreground,
      tertiary: palette.accentSecondary,
      onTertiary: onAccent,
      surface: panel,
      onSurface: foreground,
      surfaceDim: canvas,
      surfaceBright: panelElevated,
      surfaceContainer: panel,
      surfaceContainerHigh: panelElevated,
      surfaceContainerHighest: panelElevated,
      surfaceContainerLow: canvas,
      surfaceContainerLowest: canvas,
      onSurfaceVariant: muted,
      outline: border,
      outlineVariant: hairline,
      error: palette.danger,
      onError: onAccent,
      errorContainer: Color.alphaBlend(
        palette.danger.withValues(alpha: 0.18),
        panel,
      ),
      onErrorContainer: foreground,
      surfaceTint: Colors.transparent,
      shadow: Colors.transparent,
      inverseSurface: foreground,
      onInverseSurface: canvas,
      inversePrimary: accent,
    );

    final textTheme = _buildTextTheme(
      foreground: foreground,
      muted: muted,
      subtle: subtle,
    );
    final mono = monoFontFamily;
    final desktop = PlatformFeatures.isDesktop;

    return ThemeData(
      useMaterial3: true,
      brightness: themeBrightness,
      colorScheme: colorScheme,
      extensions: [AppPaletteTheme(palette)],
      scaffoldBackgroundColor: canvas,
      canvasColor: canvas,
      // A mouse click shows no ripple on desktop, and hover is visible.
      splashFactory: desktop ? NoSplash.splashFactory : InkRipple.splashFactory,
      highlightColor: foreground.withValues(alpha: 0.08),
      splashColor: foreground.withValues(alpha: 0.08),
      hoverColor: foreground.withValues(alpha: desktop ? 0.08 : 0.04),
      focusColor: accent.withValues(alpha: 0.18),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: muted, size: 22),
      primaryIconTheme: IconThemeData(color: foreground),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.35),
        selectionHandleColor: accent,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: canvas,
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        systemOverlayStyle: systemUiOverlayStyle(themeBrightness),
        shape: Border(bottom: BorderSide(color: hairline)),
        titleTextStyle: textTheme.titleMedium,
      ),
      cardTheme: CardThemeData(
        color: panel,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: outlined(hairline),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: panelElevated,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        shape: outlined(hairline, radius: radiusLarge),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: panelElevated,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        modalBackgroundColor: panelElevated,
        modalBarrierColor: Colors.black.withValues(alpha: 0.5),
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: hairline,
        dragHandleSize: const Size(36, 3),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(radiusLarge),
          ),
          side: BorderSide(color: hairline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: accent),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: palette.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: palette.danger, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(color: hairline.withValues(alpha: 0.5)),
        ),
        filled: true,
        fillColor: panel,
        hintStyle: textTheme.bodyMedium?.copyWith(color: subtle),
        labelStyle: textTheme.bodyMedium?.copyWith(color: muted),
        floatingLabelStyle: textTheme.labelLarge?.copyWith(color: accent),
        prefixIconColor: muted,
        suffixIconColor: muted,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 46),
          backgroundColor: accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: panelElevated,
          disabledForegroundColor: subtle,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: square,
          textStyle: textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          backgroundColor: panelElevated,
          foregroundColor: foreground,
          shape: outlined(hairline),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: textTheme.labelLarge,
          shape: square,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          side: BorderSide(color: border),
          shape: square,
          minimumSize: const Size(64, 46),
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: foreground, shape: square),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
        shape: square,
        extendedTextStyle: textTheme.labelLarge,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: panelElevated,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        shape: outlined(hairline),
        textStyle: textTheme.bodyMedium,
        labelTextStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(panelElevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(outlined(hairline)),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: textTheme.bodyMedium,
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(panelElevated),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          shape: WidgetStatePropertyAll(outlined(hairline)),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: panel,
        selectedColor: selected,
        disabledColor: panel,
        side: BorderSide(color: hairline),
        labelStyle: textTheme.labelMedium?.copyWith(color: foreground),
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: foreground),
        checkmarkColor: accent,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        shape: square,
        elevation: 0,
        pressElevation: 0,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: panel,
          foregroundColor: muted,
          selectedBackgroundColor: selected,
          selectedForegroundColor: accent,
          side: BorderSide(color: hairline),
          shape: square,
          textStyle: textTheme.labelMedium,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? onAccent : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : panel,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : hairline,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(2)),
        ),
        side: BorderSide(color: border, width: 1.5),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(onAccent),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? accent : border,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: hairline,
        thumbColor: accent,
        overlayColor: accent.withValues(alpha: 0.12),
        valueIndicatorColor: panelElevated,
        valueIndicatorTextStyle: textTheme.labelMedium?.copyWith(
          color: foreground,
        ),
        trackHeight: 2,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: muted,
        textColor: foreground,
        selectedColor: accent,
        selectedTileColor: selected,
        shape: square,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: accent,
        unselectedLabelColor: muted,
        indicatorColor: accent,
        dividerColor: hairline,
        labelStyle: textTheme.labelLarge,
        unselectedLabelStyle: textTheme.labelLarge,
        indicatorSize: TabBarIndicatorSize.tab,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: canvas,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        indicatorColor: selected,
        indicatorShape: square,
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelSmall),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: accent,
        textColor: onAccent,
        textStyle: textTheme.labelSmall,
      ),
      dividerTheme: DividerThemeData(color: hairline, space: 1, thickness: 1),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: panelElevated,
          borderRadius: borderRadius,
          border: Border.all(color: hairline),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: foreground,
          fontFamily: mono,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: panelElevated,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: foreground),
        actionTextColor: accent,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: outlined(hairline),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: accent,
        linearTrackColor: hairline,
        circularTrackColor: hairline,
      ),
      scrollbarTheme: desktop
          // Wide enough to see and grab with a mouse; wider under it.
          ? ScrollbarThemeData(
              thumbColor: WidgetStateProperty.resolveWith(
                (states) => muted.withValues(
                  alpha:
                      states.contains(WidgetState.dragged) ||
                          states.contains(WidgetState.hovered)
                      ? 0.55
                      : 0.3,
                ),
              ),
              thickness: WidgetStateProperty.resolveWith(
                (states) =>
                    states.contains(WidgetState.dragged) ||
                        states.contains(WidgetState.hovered)
                    ? 9
                    : 6,
              ),
              radius: const Radius.circular(4),
              interactive: true,
            )
          : ScrollbarThemeData(
              thumbColor: WidgetStateProperty.all(hairline),
              thickness: WidgetStateProperty.all(3),
              radius: Radius.zero,
            ),
    );
  }

  static TextTheme _buildTextTheme({
    required Color foreground,
    required Color muted,
    required Color subtle,
  }) {
    // Headings and labels in the monospace, like Omarchy's bar, launcher
    // and menus; running text stays in the system sans for reading.
    final mono = monoFontFamily;
    TextStyle heading(double size, double height) => TextStyle(
      color: foreground,
      fontFamily: mono,
      fontSize: size,
      height: height,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    );
    return TextTheme(
      displayLarge: heading(48, 1.1),
      displayMedium: heading(38, 1.1),
      displaySmall: heading(30, 1.15),
      headlineLarge: heading(26, 1.2),
      headlineMedium: heading(22, 1.2),
      headlineSmall: heading(19, 1.25),
      titleLarge: heading(17, 1.3),
      titleMedium: heading(15, 1.35),
      titleSmall: heading(13.5, 1.4),
      bodyLarge: TextStyle(
        color: foreground,
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w400,
      ),
      bodyMedium: TextStyle(
        color: foreground,
        fontSize: 14,
        height: 1.5,
        fontWeight: FontWeight.w400,
      ),
      bodySmall: TextStyle(
        color: muted,
        fontSize: 12.5,
        height: 1.45,
        fontWeight: FontWeight.w400,
      ),
      labelLarge: TextStyle(
        color: foreground,
        fontFamily: mono,
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      labelMedium: TextStyle(
        color: muted,
        fontFamily: mono,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      labelSmall: TextStyle(
        color: subtle,
        fontFamily: mono,
        fontSize: 10.5,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.2,
      ),
    );
  }
}
