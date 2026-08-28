#!/usr/bin/env bash
# Installe TermiClaude comme LaunchAgent : lancement automatique a l'ouverture de session
# macOS, et relance auto en cas de crash uniquement (un "Quitter" depuis le menu reste
# effectif jusqu'au prochain login). Idempotent (recharge si deja installe).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

LABEL="com.julienchateau.termiclaude"
BIN="$REPO/app/TermiClaude.app/Contents/MacOS/TermiClaude"
LOG="$HOME/Library/Logs/TermiClaude.log"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"

if [ ! -x "$BIN" ]; then
  echo "Binaire introuvable : $BIN" >&2
  echo "Construis d'abord l'app :  bash \"$REPO/app/build.sh\"" >&2
  exit 1
fi

mkdir -p "$AGENTS_DIR" "$(dirname "$LOG")"

# Genere le plist final depuis le modele en resolvant les chemins absolus.
sed -e "s#__TERMICLAUDE_BIN__#$BIN#g" \
    -e "s#__TERMICLAUDE_LOG__#$LOG#g" \
    "$HERE/$LABEL.plist" > "$PLIST"

# Recharge proprement (bootout ignore si pas encore charge).
UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true

# Le domaine peut ne pas avoir encore libere le label juste apres le bootout : bootstrap
# repond alors "Input/output error" (5). On retente quelques fois avant d'abandonner.
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "Echec du chargement du LaunchAgent :" >&2
    launchctl bootstrap "gui/$UID_NUM" "$PLIST" >&2
    exit 1
  fi
  sleep 1
done

launchctl enable "gui/$UID_NUM/$LABEL"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "TermiClaude installe au demarrage."
echo "  plist : $PLIST"
echo "  binaire : $BIN"
echo "  log   : $LOG"
