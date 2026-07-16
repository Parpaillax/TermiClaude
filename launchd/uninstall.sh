#!/usr/bin/env bash
# Retire HyperClaude du demarrage automatique (decharge le LaunchAgent et supprime le plist).
set -euo pipefail

LABEL="com.julienchateau.hyperclaude"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "HyperClaude retire du demarrage automatique."
