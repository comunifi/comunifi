import 'package:flutter/cupertino.dart';

/// Global color tokens for the Comunifi app.
///
/// These are semantic colors – prefer using them by intent (background,
/// primary, accent, surface, etc.) rather than by specific hex value so the
/// palette can evolve without touching call‑sites.
class AppColors {
  AppColors._();

  /// App background, inspired by the brand's light sand tone.
  static const Color background = Color(0xFFFDEFD9); // #FDEFD9

  /// Primary brand color – main CTAs, active states.
  static const Color primary = Color(0xFFFE9B2D); // #FE9B2D

  /// Softer primary for fills, chips, and subtle highlights.
  static const Color primarySoft = Color(0xFFFEBF5D); // #FEBF5D

  /// Accent color used for reactions, highlights and special CTAs.
  static const Color accent = Color(0xFFFF732F); // #FF732F

  /// Base surface for cards and panels that sit above the background.
  static const Color surface = Color(0xFFFFF6EC); // slightly lighter than background

  /// More elevated surface for modals and important panels.
  static const Color surfaceElevated = Color(0xFFFFE3BF);

  /// Soft chip/pill backgrounds (e.g. tags, subtle badges).
  static const Color chipBackground = Color(0xFFFFF3E0);

  /// Warm separator / divider color that works on the light background.
  static const Color separator = Color(0xFFE9D3B8);

  /// Text colors – keep Cupertino defaults but expose them here for consistency.
  static const Color label = CupertinoColors.label;
  static const Color secondaryLabel = CupertinoColors.secondaryLabel;
  static const Color tertiaryLabel = CupertinoColors.tertiaryLabel;

  /// Error and warning colors – keep close to Cupertino red/orange so they read
  /// as system alerts while still fitting the warm palette.
  static const Color error = CupertinoColors.systemRed;
  static const Color errorBackground = Color(0xFFFFE4E0);

  static const Color warning = accent;
  static const Color warningBackground = Color(0xFFFFF0E5);

  /// Muted fill for offline / information banners.
  static const Color infoBackground = Color(0xFFFFF7EB);

  /// Outline / stroke color for warm, subtle borders.
  static const Color outline = Color(0xFFE2C9AA);
}

