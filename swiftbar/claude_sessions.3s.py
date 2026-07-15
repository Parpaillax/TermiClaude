#!/usr/bin/env python3
# <xbar.title>HyperClaude - sessions Claude Code</xbar.title>
# <xbar.version>0.1.0</xbar.version>
# <xbar.author>Julien Chateau</xbar.author>
# <xbar.desc>Supervise les sessions Claude Code (Hyper) : statut, attente, focus.</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
"""Plugin SwiftBar (POC L1) du widget HyperClaude.

Deux modes :
  - sans argument      : rend le menu SwiftBar (icone + liste des sessions).
  - ``--focus <tty>``  : action best-effort de mise au premier plan de Hyper.

Le script se resout lui-meme vers la racine du depot (via ``__file__`` resolu), de sorte
qu'il fonctionne meme installe en lien symbolique dans le dossier de plugins SwiftBar.

Installation (voir README) :
  ln -s <repo>/swiftbar/claude_sessions.3s.py "<dossier plugins SwiftBar>/"
  chmod +x <repo>/swiftbar/claude_sessions.3s.py
Le suffixe ``.3s`` fixe le rafraichissement a 3 s.
"""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Rendre le paquet hyperclaude importable, que le fichier soit lance direct ou en symlink.
REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

SELF = str(Path(__file__).resolve())
HOME = str(Path.home())

# Presentation par statut : (puce, libelle, couleur SwiftBar).
STATUS_STYLE = {
    "waiting": ("🟠", "attend une action", "#d9822b"),
    "busy":    ("🔵", "travaille",         "#3b6fe0"),
    "idle":    ("⚪️", "au repos",          "#8a93a2"),
    "unknown": ("⚫️", "etat inconnu",      "#8a93a2"),
}


def _shorten(path: str | None) -> str:
    if not path:
        return "-"
    return path.replace(HOME, "~", 1)


def do_focus(tty: str | None) -> int:
    """Action best-effort (P1) : activer Hyper au premier plan.

    Le focus *precis* de la bonne fenetre viendra avec le plugin Hyper (palier 3) ;
    ce point d'extension recevra alors le tty pour cibler la fenetre exacte.
    """
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "Hyper" to activate'],
            check=False,
            capture_output=True,
        )
    except OSError:
        pass
    return 0


def _emit_session(entry) -> None:
    dot, label, color = STATUS_STYLE.get(entry.status, STATUS_STYLE["unknown"])
    name = entry.name or f"pid {entry.pid}"
    stale = " · inactive" if entry.stale else ""

    if entry.focusable and entry.tty:
        # Ligne cliquable : declenche l'action de focus best-effort.
        print(
            f"{dot} {name} | color={color} font=Menlo "
            f'shell="{SELF}" param1="--focus" param2="{entry.tty}" '
            f"terminal=false refresh=false"
        )
    else:
        print(f"{dot} {name} (non localisable) | color={color} font=Menlo")

    # Sous-menu : details de reperage (non cliquables).
    print(f"-- {label}{stale}")
    if entry.waiting_for:
        print(f"-- attend : {entry.waiting_for} | color={color}")
    print(f"-- dossier : {_shorten(entry.cwd)} | font=Menlo")
    print(f"-- terminal : {entry.tty or 'non resolu'} | font=Menlo")
    if entry.version:
        print(f"-- version : {entry.version} | color=#8a93a2 font=Menlo")


def render() -> int:
    try:
        from hyperclaude import collect
        sessions = collect()
    except Exception as exc:  # noqa: BLE001 - un plugin ne doit jamais planter l'affichage
        print("⚠️ HyperClaude")
        print("---")
        print(f"Erreur de collecte : {exc} | color=#d64545")
        return 0

    waiting = [s for s in sessions if s.status == "waiting"]

    # --- Ligne de barre de menus : neutre si rien n'attend, sinon compteur d'alerte.
    if waiting:
        print(f"🟠 {len(waiting)} | color=#d9822b")
    else:
        print("✳️")

    print("---")

    if not sessions:
        print("Aucune session Claude Code active | color=#8a93a2")
    else:
        for entry in sessions:
            _emit_session(entry)

    # --- Pied de menu.
    print("---")
    print(
        f"{len(sessions)} session(s) · {len(waiting)} en attente | color=#8a93a2 font=Menlo"
    )
    print(f"Mis a jour {datetime.now().strftime('%H:%M:%S')} | color=#8a93a2 font=Menlo")
    print("Rafraichir maintenant | refresh=true")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "--focus":
        return do_focus(argv[1])
    if argv and argv[0] == "--focus":
        return do_focus(None)
    return render()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
