## Typography

Comunifi uses a warm, rounded sans‑serif typeface to match the friendly,
community‑focused visual style of the app.

### Font family

- **Primary family**: `ComunifiRounded`
- **Implementation**: backed by the bundled Nunito variable font at
  `assets/fonts/Nunito-Regular.ttf`

This family is registered in `pubspec.yaml` and wired into the global
`CupertinoThemeData` in `lib/theme/app_theme.dart`, so widgets should rely
on the theme instead of specifying their own `fontFamily`.

### Weights and usage

- **400 – Regular**: default body text, long-form copy, helper text
- **500 – Medium**: sidebar labels, secondary buttons, small emphasis
- **600 – Semibold**: primary buttons, key labels, important badges
- **700 – Bold**: large titles and major section headings only

### Usage guidelines

- **Default**: Prefer the theme’s default `textStyle`; avoid hard-coding
  `fontFamily` in widgets.
- **Buttons**: Use medium/semibold weights (`w500–w600`) for primary CTAs;
  keep destructive actions red but still use the same family.
- **Badges and pills**: Use `w600` with all‑caps or short labels for clarity.
- **Status/error text**: Reuse the same font with color changes (e.g. error
  red, warning orange) rather than switching families or using italics
  heavily.

When adding new screens or components, start from the theme’s text styles
and adjust only `fontSize`, `fontWeight`, and `color` as needed so the
app’s typography stays cohesive.

