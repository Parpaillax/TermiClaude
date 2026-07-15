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

echo "==> signature ad hoc"
# Ad hoc : suffisant en dev. Une vraie identite Developer ID stabilise le "Toujours autoriser" du Keychain.
codesign --force --sign - "$APP" 2>/dev/null || echo "   (codesign ignore)"

echo "OK -> $APP"
echo "Lancer : open \"$APP\""
