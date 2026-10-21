#!/bin/bash
# Double-click installer: runs install.sh from this same folder.
cd "$(dirname "$0")" && bash install.sh
echo ""; echo "Press Return to close."; read -r _
