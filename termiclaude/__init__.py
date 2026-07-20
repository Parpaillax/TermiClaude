"""TermiClaude - widget de supervision des sessions Claude Code sous Terminal.app.

Ce paquet regroupe le coeur transverse (L0) reutilise par tous les paliers du widget :
collecte et normalisation de l'etat des sessions Claude Code, filtrage des sessions
mortes, et resolution du mapping session -> fenetre du Terminal (tty).
"""

from .collector import SessionEntry, collect, to_json

__all__ = ["SessionEntry", "collect", "to_json"]
__version__ = "0.1.0"
