# App icon sources

Not bundled into the app; these are the masters every platform icon was
made from.

- `full.svg`: the icon (gradient background, coin with its aura). Rendered
  at 1024 px as `icon-1024.png`.
- `foreground.svg`: the mark alone, scaled into the safe zone of an Android
  adaptive icon (also the splash screen mark).
- `mono.svg`: one-colour version for Android 13 themed icons.
- `mark.svg`: the mark alone at full size (iOS launch image).

Brand colour `#2C6286` (Android `@color/brand`, the iOS launch screen,
`web/manifest.json`). To regenerate the sizes, render each SVG to a
1024 px PNG and scale it down: Android `mipmap-*/ic_launcher*.png` (48,
108 dp), iOS `AppIcon.appiconset` (every size in its `Contents.json`,
opaque, no alpha), `LaunchImage.imageset` (120/240/360 px) and
`web/icons`.
