#!/bin/zsh
# Builds GuiCondicionado.app. Build products live outside the (iCloud-synced) project folder, because
# iCloud's Finder metadata breaks code signing and would sync hundreds of MB.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build, copy to ~/Applications and (re)launch
set -euo pipefail

ROOT=${0:A:h:h}
SCRATCH="$HOME/Library/Caches/guicondicionado-build"
APP="$SCRATCH/GuiCondicionado.app"
cd "$ROOT"

swift build -c release --scratch-path "$SCRATCH" --product GuiCondicionado
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/GuiCondicionado"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GuiCondicionado"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
xattr -cr "$APP"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x GuiCondicionado 2>/dev/null || true
  rm -rf "$HOME/Applications/GuiCondicionado.app"
  ditto "$APP" "$HOME/Applications/GuiCondicionado.app"
  open "$HOME/Applications/GuiCondicionado.app"
  echo "Instalado em ~/Applications/GuiCondicionado.app"
else
  echo "$APP"
fi
