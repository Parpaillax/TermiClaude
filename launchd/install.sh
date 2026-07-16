#!/usr/bin/env bash
# Installe HyperClaude comme LaunchAgent : lancement automatique a l'ouverture de session
# macOS, et relance auto si l'app se ferme. Idempotent (recharge si deja installe).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

LABEL="com.julienchateau.hyperclaude"
BIN="$REPO/app/HyperClaude.app/Contents/MacOS/HyperClaude"
LOG="$HOME/Library/Logs/HyperClaude.log"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"

if [ ! -x "$BIN" ]; then
  echo "Binaire introuvable : $BIN" >&2
  echo "Construis d'abord l'app :  bash \"$REPO/app/build.sh\"" >&2
  exit 1
fi

mkdir -p "$AGENTS_DIR" "$(dirname "$LOG")"

# Genere le plist final depuis le modele en resolvant les chemins absolus.
sed -e "s#__HYPERCLAUDE_BIN__#$BIN#g" \
    -e "s#__HYPERCLAUDE_LOG__#$LOG#g" \
    "$HERE/$LABEL.plist" > "$PLIST"

# Recharge proprement (bootout ignore si pas encore charge).
UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "HyperClaude installe au demarrage."
echo "  plist : $PLIST"
echo "  binaire : $BIN"
echo "  log   : $LOG"
