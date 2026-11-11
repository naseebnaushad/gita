#!/usr/bin/env bash
# Usage: stage.sh <flutter linux bundle dir> <staging root>
# Produces the file layout shared by the .deb, .rpm and Arch packages:
#   /opt/gita/...                     the app (and its cli/ folder)
#   /usr/bin/gita                     the gita command
#   /usr/bin/gita-app                 starts the desktop app
#   /usr/share/applications/gita.desktop, icon
set -euo pipefail
bundle=$1 root=$2
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

install -d "$root/opt/gita" "$root/usr/bin" "$root/usr/share/applications" \
  "$root/usr/share/icons/hicolor/1024x1024/apps"
cp -a "$bundle/." "$root/opt/gita/"
ln -s /opt/gita/cli/bin/gita "$root/usr/bin/gita"
ln -s /opt/gita/gita "$root/usr/bin/gita-app"
install -m 644 "$here/gita.desktop" "$root/usr/share/applications/gita.desktop"
install -Dm 644 "$repo/LICENSE" "$root/usr/share/licenses/gita/LICENSE"
install -m 644 "$repo/assets/branding/icon.png" "$root/usr/share/icons/hicolor/1024x1024/apps/gita.png"
