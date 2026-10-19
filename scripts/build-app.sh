#!/bin/zsh
# Builds the menu bar app. Build products live outside the (iCloud-synced) project folder, because
# iCloud's Finder metadata breaks code signing and would sync hundreds of MB.
#   scripts/build-app.sh                      build only, print the .app path
#   scripts/build-app.sh --install            build, copy to ~/Applications and (re)launch
#   scripts/build-app.sh --name "GuiCondicionado" [--install]
#       names the app (menu bar menu, Activity Monitor, "Sair do …") and saves the name for later builds
#
# Per-user settings live in ~/.config/ac-menubar/app.env, KEY=value lines (read, never executed):
#   APP_NAME   the app's name; default "ac-menubar"
#   BUNDLE_ID  optional; default local.ac-menubar.<name>. macOS ties the Local Network permission and
#              the login item to it, so a new id (a new name, without BUNDLE_ID) asks for them again.
set -euo pipefail
setopt extendedglob

ROOT=${0:A:h:h}
SETTINGS="$HOME/.config/ac-menubar/app.env"
SCRATCH="$HOME/Library/Caches/ac-menubar-build"

usage() { print -u2 'uso: scripts/build-app.sh [--name "Nome do app"] [--install]'; exit 2 }

# "Ar da Júlia" -> "Ar da Julia"; other non-ASCII characters are dropped. macOS's iconv transliterates
# "ú" as "'u" and fails, so the common accents are mapped here.
asciify() {
  local s=$1
  s=${s//[áàâãä]/a}; s=${s//[ÁÀÂÃÄ]/A}; s=${s//[éèêë]/e}; s=${s//[ÉÈÊË]/E}
  s=${s//[íìîï]/i}; s=${s//[ÍÌÎÏ]/I}; s=${s//[óòôõö]/o}; s=${s//[ÓÒÔÕÖ]/O}
  s=${s//[úùûü]/u}; s=${s//[ÚÙÛÜ]/U}; s=${s//ç/c}; s=${s//Ç/C}; s=${s//ñ/n}; s=${s//Ñ/N}
  print -r -- "${s//[^ -~]/}"
}

# "Ar da Júlia" -> "ar-da-julia"
slugify() {
  local s=${(L)$(asciify "$1")}
  s=${s//[^a-z0-9]##/-}
  s=${s#-}; s=${s%-}
  print -r -- "$s"
}

APP_NAME="" BUNDLE_ID="" NEW_NAME="" INSTALL=0
if [[ -f "$SETTINGS" ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      APP_NAME) APP_NAME=$value ;;
      BUNDLE_ID) BUNDLE_ID=$value ;;
    esac
  done < "$SETTINGS"
fi

while (( $# )); do
  case "$1" in
    --name) (( $# >= 2 )) || usage; NEW_NAME=$2; shift 2 ;;
    --install) INSTALL=1; shift ;;
    *) usage ;;
  esac
done

if [[ -n "$NEW_NAME" ]]; then
  if [[ "$NEW_NAME" == *[/:=$'\n']* || "$NEW_NAME" == .* || ${#NEW_NAME} -gt 40 ]]; then
    print -u2 "Nome inválido: use até 40 caracteres, sem / : = e sem começar com ponto."
    exit 2
  fi
  APP_NAME=$NEW_NAME
  mkdir -p -m 700 "${SETTINGS:h}"
  {
    print -r -- "APP_NAME=$APP_NAME"
    if [[ -n "$BUNDLE_ID" ]]; then print -r -- "BUNDLE_ID=$BUNDLE_ID"; fi
  } > "$SETTINGS"
  print "Nome salvo em ${SETTINGS/#$HOME/~}: $APP_NAME"
fi

APP_NAME=${APP_NAME:-ac-menubar}
# codesign seals a bundle whose main executable has a non-ASCII name as invalid, so the executable
# drops the accents; the .app and the names macOS shows keep them.
EXEC=$(asciify "$APP_NAME")
EXEC=${EXEC## #}; EXEC=${EXEC%% #}
if [[ -z "$EXEC" || "$EXEC" == .* ]]; then EXEC=ac-menubar; fi
if [[ -z "$BUNDLE_ID" ]]; then
  slug=$(slugify "$APP_NAME")
  if [[ -z "$slug" || "$slug" == ac-menubar ]]; then BUNDLE_ID=local.ac-menubar; else BUNDLE_ID=local.ac-menubar.$slug; fi
fi

cd "$ROOT"
swift build -c release --scratch-path "$SCRATCH" --product ac-menubar
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/ac-menubar"

APP="$SCRATCH/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$PLIST"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleExecutable -string "$EXEC" "$PLIST"
plutil -replace NSLocalNetworkUsageDescription \
  -string "$APP_NAME conversa com o seu ar-condicionado pela rede da sua casa." "$PLIST"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  plutil -replace CFBundleIconFile -string AppIcon "$PLIST"
fi
xattr -cr "$APP"
codesign --force --sign - "$APP"

if (( INSTALL )); then
  mkdir -p "$HOME/Applications"
  pkill -x "$EXEC" 2>/dev/null || true
  rm -rf "$HOME/Applications/$APP_NAME.app"
  ditto "$APP" "$HOME/Applications/$APP_NAME.app"
  open "$HOME/Applications/$APP_NAME.app"
  print "Instalado em ~/Applications/$APP_NAME.app ($BUNDLE_ID)"
else
  print -r -- "$APP"
fi
