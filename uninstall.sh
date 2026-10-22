#!/bin/bash
# Удаляет WGMenu. Конфиги в /etc/wireguard не трогает.
set -uo pipefail
launchctl bootout "gui/$(id -u)/local.wgmenu" 2>/dev/null
sudo rm -f /Library/LaunchAgents/local.wgmenu.plist /etc/sudoers.d/wgmenu /Library/PrivilegedHelperTools/wgmenu-helper
sudo rm -rf /Applications/WGMenu.app
echo "WGMenu удалён. Конфиги в /etc/wireguard оставлены."
