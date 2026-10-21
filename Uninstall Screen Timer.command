#!/bin/bash
# Screen Timer — uninstaller. Removes the module; leaves Hammerspoon itself.
set -u
osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1 || true
sleep 1; pkill -x Hammerspoon >/dev/null 2>&1 || true
sed -i '' '/require("screen-timer")/d' "$HOME/.hammerspoon/init.lua" 2>/dev/null || true
rm -f "$HOME/.hammerspoon/screen-timer.lua"
echo "Screen Timer removed. (~/screen-stays.csv kept — delete it manually if you want.)"
open -a Hammerspoon >/dev/null 2>&1 || true
echo "Press Return to close."; read -r _
