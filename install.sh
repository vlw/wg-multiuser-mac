#!/bin/bash
# Сборка и установка WGMenu. Запускать от админа: ./install.sh (sudo спросит пароль один раз).
set -euo pipefail
cd "$(dirname "$0")"

# Кому разрешено включать/выключать туннели. staff = все обычные локальные пользователи.
ALLOW_GROUP=${ALLOW_GROUP:-staff}

APP=/Applications/WGMenu.app
HELPER=/Library/PrivilegedHelperTools/wgmenu-helper
SUDOERS=/etc/sudoers.d/wgmenu
AGENT=/Library/LaunchAgents/local.wgmenu.plist

echo "==> Сборка"
BUILD=$(mktemp -d)
mkdir -p "$BUILD/WGMenu.app/Contents/MacOS"
cp app/Info.plist "$BUILD/WGMenu.app/Contents/"
swiftc -swift-version 5 -O shared/*.swift helper/main.swift -o "$BUILD/wgmenu-helper"
swiftc -swift-version 5 -O shared/*.swift app/*.swift -o "$BUILD/WGMenu.app/Contents/MacOS/WGMenu" \
	-framework AppKit -framework SwiftUI
codesign --force --sign - "$BUILD/wgmenu-helper"
codesign --force --sign - "$BUILD/WGMenu.app"

echo "==> Установка (нужен пароль администратора)"
sudo -v

sudo rm -rf "$APP"
sudo cp -R "$BUILD/WGMenu.app" "$APP"
sudo chown -R root:wheel "$APP"

sudo install -o root -g wheel -m 755 "$BUILD/wgmenu-helper" "$HELPER"
rm -rf "$BUILD"

sudo install -d -o root -g wheel -m 700 /etc/wireguard

TMP=$(mktemp)
echo "%$ALLOW_GROUP ALL=(root) NOPASSWD: $HELPER" >"$TMP"
visudo -cf "$TMP" >/dev/null
sudo install -o root -g wheel -m 440 "$TMP" "$SUDOERS"
rm -f "$TMP"

sudo tee "$AGENT" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>local.wgmenu</string>
	<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/WGMenu</string></array>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
EOF
sudo chown root:wheel "$AGENT"
sudo chmod 644 "$AGENT"

# Перезапуск агента в текущей сессии
launchctl bootout "gui/$(id -u)/local.wgmenu" 2>/dev/null || true
# bootout завершается асинхронно — ждём, пока сервис действительно выгрузится
for _ in {1..50}; do
	launchctl print "gui/$(id -u)/local.wgmenu" >/dev/null 2>&1 || break
	sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo
echo "Готово. Положите конфиги в /etc/wireguard/<имя>.conf (имя ≤15 символов), например:"
echo "  sudo install -o root -g wheel -m 600 work1.conf /etc/wireguard/"
echo "Другие пользователи получат значок в трее при следующем входе."
