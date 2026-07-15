# HyperClaude

Widget de barre de menus macOS pour **superviser en un coup d'oeil ses sessions Claude Code**
reparties dans plusieurs fenetres [Hyper](https://hyper.is), signaler celles qui attendent
une action, et basculer vers la bonne fenetre.

> Cadrage complet (cahier des charges) : voir le dossier `hyper_claude_mac_widget` du
> workspace Beehelp (`_scratch/claude/CdCs/`). Ce depot ne contient que le code.

## Trajectoire par paliers

| Palier | Contenu | Etat |
|--------|---------|------|
| L0 | Socle : collecte + normalisation de l'etat des sessions, mapping vers la fenetre | **en cours** |
| L1 | POC SwiftBar (menu, statuts, highlight, focus best-effort) | a venir |
| L2 | App native SwiftUI (badge, FSEvents) + footer d'usage | a venir |
| L3 | Plugin Hyper (focus fenetre fiable) | a venir |

## L0 - Socle de collecte (`hyperclaude/collector.py`)

Lit les fichiers d'etat natifs de Claude Code, sans hook ni ecriture :

- **Source** : `~/.claude/sessions/<pid>.json` (statut `busy`/`idle`/`waiting`, `waitingFor`,
  `cwd`, `name`, `sessionId`, `updatedAt`, ...). Format non contractuel (teste sur Claude
  Code 2.1.210) -> parsing defensif.
- **Vivacite** : une session est retenue si son process est vivant (`kill -0`). Les fichiers
  residuels (process mort) sont ecartes. Une session inactive depuis longtemps est marquee
  `stale` mais reste affichee.
- **Mapping fenetre** : `pid -> tty` via `ps` (avec remontee au shell parent si besoin).
  `focusable = true` quand un `ttysNNN` est resolu ; sinon la session est affichee sans
  action de focus (cas tmux / SSH / detache).
- **Tri d'affichage** : en attente -> en cours -> au repos.

### Utilisation

```bash
# Etat courant des sessions vivantes, en JSON
python3 -m hyperclaude

# Inclure aussi les sessions dont le process est mort
python3 -m hyperclaude --include-dead
```

En Python :

```python
from hyperclaude import collect, to_json
print(to_json(collect()))
```

## Tests

```bash
python3 -m unittest discover -s tests -v   # stdlib uniquement, aucune dependance
```

## Contraintes

- **Lecture seule** de `~/.claude` : aucun hook, aucune modification de configuration.
- **stdlib uniquement** pour le socle (aucune dependance runtime).
- Python 3.9+.
