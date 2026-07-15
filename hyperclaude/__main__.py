"""Point d'entree du paquet : ``python3 -m hyperclaude``.

Affiche en JSON l'etat courant des sessions Claude Code (socle L0).
"""

from .collector import _main

if __name__ == "__main__":
    raise SystemExit(_main())
