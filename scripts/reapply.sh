#!/usr/bin/env bash
# After rebuilding the extension in Xcode, restart fskitd so the new bundle
# is picked up, then reopen System Settings to the FSKit Modules pane so you
# can re-toggle if needed.
set -euo pipefail

sudo killall fskitd 2>/dev/null || true
killall "System Settings" 2>/dev/null || true

# Open the Login Items & Extensions pane.
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
