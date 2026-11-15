# SPDX-License-Identifier: GPL-3.0-or-later
#
# dmgbuild settings for Minutes-<version>-arm64.dmg. scripts/build-release.sh passes the app's path
# and this folder with -D app=<path> -D here=<folder>, since dmgbuild doesn't set __file__. It writes
# the window layout itself, so it needs no Finder or GUI session.

import os.path

app = defines["app"]  # noqa: F821, dmgbuild provides `defines`
app_name = os.path.basename(app)
here = defines["here"]  # noqa: F821

format = "ULFO"  # LZFSE: smaller than zlib, and every supported macOS reads it.
filesystem = "APFS"
size = None  # Fit the contents.

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

# background@2x.png beside it is picked up for Retina screens.
background = os.path.join(here, "background.png")
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
# Taller than the background: Finder's title bar and its bottom bar take room from the content.
window_rect = ((200, 120), (660, 440))
default_view = "icon-view"
icon_size = 128
text_size = 13
# The arrow in background.png runs between these, 170 points from the top.
icon_locations = {app_name: (180, 170), "Applications": (480, 170)}
