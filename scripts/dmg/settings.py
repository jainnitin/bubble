# dmgbuild settings for Bubble's download DMG; scripts/dmg.sh passes the -D values.
# dmgbuild writes the window layout (.DS_Store) itself, so no Finder or AppleScript is involved
# and it works on a headless CI runner.
#
# Icon centres and the window size must match scripts/dmg/render-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821  volume icon: the app's AppIcon.icns

background = defines["background"]  # noqa: F821  the 1x PNG; dmgbuild adds the @2x beside it
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

# ((x, y), (width, height)) of the whole window in points, title bar included (28pt; 32pt on
# newer macOS, which crops the background's plain bottom edge a little). The background,
# and so the content area, is 660x400.
window_rect = ((200, 120), (660, 428))
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {
    app_name: (170, 185),
    "Applications": (490, 185),
}
# No hide_extensions: it sets Finder info on Bubble.app, which `codesign --verify --strict`
# rejects as detritus. Finder hides ".app" anyway unless all extensions are shown.
