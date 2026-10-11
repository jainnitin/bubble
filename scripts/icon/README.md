# App icon

`assets/AppIcon.icns` is drawn entirely in code by `render-icon.swift` (CoreGraphics and
CoreImage, no external art): an iridescent soap bubble on a deep-blue macOS tile.

To regenerate it after changing the drawing:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/icon/render-icon.swift
```

The script renders the icon at 1024 px, writes every size of a `.iconset` to a temporary
folder, and runs `iconutil` to replace `assets/AppIcon.icns`. Pass a path to write the
`.icns` somewhere else instead. `scripts/bundle.sh` copies it into the app.
