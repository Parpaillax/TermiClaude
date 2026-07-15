#!/usr/bin/env bash
# Build de l'app barre de menus HyperClaude et assemblage du bundle .app.
# Sans rm ni redirection (contraintes de l'environnement) : mkdir -p + cp -f, Info.plist source copie tel quel.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "==> swift build -c release"
swift build -c release

BIN="$HERE/.build/release/HyperClaude"
APP="$HERE/HyperClaude.app"

echo "==> assemblage $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/HyperClaude"
cp -f "$HERE/Info.plist" "$APP/Contents/Info.plist"
# Icone de l'app (Finder / launcher / cmd-tab).
if [ -f "$HERE/AppIcon.icns" ]; then
  cp -f "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Bundle de ressources SwiftPM (icone) : dans Resources (standard, trouve par Bundle.module).
if [ -d "$HERE/.build/release/HyperClaude_HyperClaude.bundle" ]; then
  cp -Rf "$HERE/.build/release/HyperClaude_HyperClaude.bundle" "$APP/Contents/Resources/"
fi

echo "==> signature ad hoc"
# Garde-fou : un bundle de ressources mal place dans MacOS casse codesign ("bundle format
# unrecognized"). On le deplace hors de l'app (pas de rm dans cet environnement).
if [ -e "$APP/Contents/MacOS/HyperClaude_HyperClaude.bundle" ]; then
  mkdir -p "$HERE/.build/stale"
  mv "$APP/Contents/MacOS/HyperClaude_HyperClaude.bundle" "$HERE/.build/stale/" 2>/dev/null || true
fi
# Ad hoc : suffisant en dev. Une vraie identite Developer ID stabilise le "Toujours autoriser" du Keychain.
codesign --force --deep --sign - "$APP" || echo "   (codesign a echoue - l'app peut etre bloquee)"

echo "OK -> $APP"
echo "Lancer : open \"$APP\""
