import 'package:flutter/cupertino.dart';

import 'colors.dart';

/// Global font family name for the app.
const String _fontFamily = 'ComunifiRounded';

/// Builds the global [CupertinoThemeData] for Comunifi.
///
/// This is the single place where we wire in brand colors and text styles.
CupertinoThemeData buildAppTheme() {
  const baseTextStyle = TextStyle(
    fontSize: 15,
    color: AppColors.label,
    fontFamily: _fontFamily,
  );

  return const CupertinoThemeData(
    brightness: Brightness.light,
    primaryColor: AppColors.primary,
    primaryContrastingColor: CupertinoColors.white,
    scaffoldBackgroundColor: AppColors.background,
    barBackgroundColor: AppColors.background,
    textTheme: CupertinoTextThemeData(
      textStyle: baseTextStyle,
      navTitleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.label,
        fontFamily: _fontFamily,
      ),
      navLargeTitleTextStyle: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: AppColors.label,
        fontFamily: _fontFamily,
      ),
      actionTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppColors.primary,
        fontFamily: _fontFamily,
      ),
      tabLabelTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.secondaryLabel,
        fontFamily: _fontFamily,
      ),
    ),
    applyThemeToAll: true,
  );
}

