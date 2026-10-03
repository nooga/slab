# dmgbuild settings for Slab-<version>.dmg (tools/package_app.sh --dmg).
# The window is the faceplate in dmg-background.png; icon positions
# match APP and APPS in make_dmg_background.py.
#
# defines: app (the .app), background (the retina .tiff), icon (.icns)

import os

app = defines["app"]  # noqa: F821 (dmgbuild provides defines)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
# 400 pt of panel under a 32 pt title bar.
window_rect = ((200, 140), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
arrange_by = None
label_pos = "bottom"
icon_locations = {
    app_name: (164, 196),
    "Applications": (476, 196),
}
