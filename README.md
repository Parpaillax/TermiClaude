<p align="center">
  <img src="assets/logo.png" alt="Logo TermiClaude" width="160" height="160">
</p>

<h1 align="center">TermiClaude</h1>

Widget de barre de menus macOS pour **superviser en un coup d'oeil ses sessions Claude Code**
reparties dans plusieurs fenetres du **Terminal natif macOS** (`Terminal.app`), signaler
celles qui attendent une action, et basculer vers la bonne fenetre.

> Cadrage complet (cahier des charges) : voir le dossier `hyper_claude_mac_widget` du
> workspace Beehelp (`_scratch/claude/CdCs/`). Ce depot ne contient que le code.

> **Origine** : ce depot est un fork de
> [HyperClaude](https://github.com/JulienCHATEAU/HyperClaude) par Julien Chateau, la
> version originelle pensee pour le terminal [Hyper](https://hyper.is) (necessitant le
> `hyper-plugin` compagnon pour le focus fenetre). TermiClaude en reprend le socle L0/L1/L2
> et remplace la dependance a Hyper par un focus natif via AppleScript sur `Terminal.app`
> macOS (voir palier L3) - plus aucun plugin tiers a installer.

## Trajectoire par paliers

| Palier | Contenu | Etat |
|--------|---------|------|
| L0 | Socle : collecte + normalisation de l'etat des sessions, mapping vers la fenetre | **fait** |
| L1 | POC SwiftBar (menu, statuts, highlight, focus) | **fait** |
| L2 | App native AppKit (badge, FSEvents) + footer d'usage | **fait (v1)** |
| L3 | Focus fenetre fiable via AppleScript natif (`Terminal.app`) | **fait** |

## L0 - Socle de collecte (`termiclaude/collector.py`)

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
python3 -m termiclaude

# Inclure aussi les sessions dont le process est mort
python3 -m termiclaude --include-dead
```

En Python :

```python
from termiclaude import collect, to_json
print(to_json(collect()))
```

## L1 - POC SwiftBar (`swiftbar/claude_sessions.3s.py`)

Plugin [SwiftBar](https://swiftbar.app) qui consomme le socle L0 et rend le menu :

- **Icone** : neutre (`✳️`) quand rien n'attend ; compteur d'alerte (`🟠 N`) des qu'au
  moins une session est en attente.
- **Menu** : une entree par session (triees attente -> en cours -> au repos), avec puce de
  statut coloree, et en sous-menu le dossier, le terminal (`tty`), la nature de l'attente
  et la version.
- **Clic sur une session** : focus precis de l'onglet `Terminal.app` correspondant (le
  `tty` est resolu au palier L0, l'AppleScript natif de Terminal fait le reste - voir L3).
- **Pied** : compteur global, horodatage, "Rafraichir maintenant".

Le suffixe `.3s` du nom de fichier fixe le rafraichissement a 3 s.

### Installation

SwiftBar doit etre installe, puis (etapes manuelles - le bit executable et le lien sont a
poser soi-meme) :

```bash
chmod +x ~/Documents/TermiClaude/swiftbar/claude_sessions.3s.py
ln -s ~/Documents/TermiClaude/swiftbar/claude_sessions.3s.py \
      "<dossier de plugins SwiftBar>/claude_sessions.3s.py"
```

Le script se resout lui-meme vers ce depot (via `__file__`), donc le lien symbolique suffit :
inutile de copier tout le paquet. Verifier le rendu hors SwiftBar :

```bash
python3 ~/Documents/TermiClaude/swiftbar/claude_sessions.3s.py
```

## Usage / quota (footer, `termiclaude/usage.py`) - source derisquee

Lecteur des pourcentages d'usage, pret a alimenter le footer en L2 (pas encore branche a
l'UI). Source confirmee et testee en live :

- **Endpoint** : `GET https://api.anthropic.com/api/oauth/usage`
  (headers `Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20`).
- **Token** : Keychain macOS, service `Claude Code-credentials` -> `claudeAiOauth.accessToken`.
- **Extraction** : tableau `limits` -> `kind="session"` (% session) et `kind="weekly_all"`
  (% hebdo tous modeles, **hors Fable** : Fable a sa propre limite `weekly_scoped`). Repli
  sur `five_hour` / `seven_day`.
- **Robustesse** : stdlib seule (`urllib`), aucune ecriture, jamais de log du token ; toute
  erreur (token absent/expire, reseau, format) -> `available=false` avec motif, jamais de
  valeur inventee.

```bash
python3 -m termiclaude.usage      # instantane JSON (peut demander une autorisation Keychain)
```

## L2 - App native de barre de menus (`app/`)

App AppKit (`NSStatusItem`) qui **reutilise le coeur Python** (une seule source de verite) :
elle invoque `python3 -m termiclaude` (sessions) et `python3 -m termiclaude.usage` (quota),
et rend un menu natif.

- **Icone** : glyphe Terminal x Claude **monochrome template** (s'inverse selon le theme de
  la barre) ; pastille rouge dessinee avec compteur des qu'une session attend.
- **Menu** : une entree par session sur deux niveaux - **titre genere par l'IA** (celui de
  `/resume`, lu dans le journal `ai-title`) en gras avec puce de statut coloree, puis
  sous-ligne (statut, dossier, tty, attente). Clic = focus precis de l'onglet Terminal.app
  correspondant (le `tty` est deja porte pour L3, cf. ci-dessous).
- **Footer** : `Session` et `Semaine` avec mini-barre + pourcentage (via `usage.py`, couleur
  selon la severite), et sous-ligne d'echeance de reset en heure locale (`reset 17h10` si
  c'est aujourd'hui, `reset 31/08 13h00` sinon), ou `Usage indisponible` a defaut - jamais
  de valeur inventee.
- **Reactivite** : FSEvents sur `~/.claude/sessions` (mise a jour quasi-instantanee) +
  poll de secours (5 s sessions, 45 s usage).
- App **agent** (`LSUIElement`) : pas d'icone Dock, vit dans la barre de menus.

### Build & lancement

```bash
bash app/build.sh                             # swift build -c release + bundle .app + signature ad hoc
open app/TermiClaude.app                      # lance le widget
./app/.build/release/TermiClaude --selftest   # verifie l'integration donnees sans lancer l'UI
```

Au premier acces au quota, macOS peut demander l'autorisation Keychain (« Toujours
autoriser »). Une vraie identite de signature (Developer ID) stabilise ce choix ; la
signature ad hoc du script suffit en dev.

## L3 - Focus fenetre fiable (AppleScript natif, sans plugin)

Au clic sur une session, le widget met **le bon onglet Terminal.app** au premier plan (fini
le « je tombe sur le mauvais terminal »).

Contrairement a Hyper (qui necessitait un plugin compagnon pour exposer ses fenetres),
`Terminal.app` expose nativement le `tty` de chaque onglet via son dictionnaire AppleScript
(`tty of tab`). Le widget n'a donc **pas besoin d'installer quoi que ce soit** :

- Il execute un `osascript` qui parcourt `windows` / `tabs of window` de `Terminal`,
  compare `tty of tab` au `tty` resolu par le collecteur (`/dev/ttysNNN`), puis
  `set selected of tab to true` + `set index of window to 1` sur le match.
- Repli si le `tty` n'est pas resolu ou introuvable (cas tmux / SSH / detache) : simple
  `activate` de Terminal.

macOS peut demander, au premier clic, l'autorisation d'automatiser Terminal (Confidentialite
et securite > Automatisation) : c'est le prompt standard pour tout controle AppleScript
inter-applications, a accepter une fois.

## Lancement au demarrage du Mac (`launchd/`)

Pour que le widget demarre tout seul a l'ouverture de session macOS (et se relance en cas
de crash), on l'enregistre comme **LaunchAgent** `launchd`. Construire l'app d'abord, puis :

```bash
bash app/build.sh                 # si pas encore fait : produit app/TermiClaude.app
bash launchd/install.sh           # enregistre + lance le widget immediatement
```

`install.sh` est idempotent : il resout les chemins absolus, ecrit le plist final dans
`~/Library/LaunchAgents/com.julienchateau.termiclaude.plist` et (re)charge l'agent via
`launchctl`. Les logs vont dans `~/Library/Logs/TermiClaude.log`.

Le `KeepAlive` est conditionne a `SuccessfulExit = false` : l'agent ne relance le widget que
s'il s'est termine anormalement. **Quitter TermiClaude** depuis le menu sort proprement et
reste donc effectif - le widget repartira a la prochaine ouverture de session (ou tout de
suite avec `launchctl kickstart gui/$(id -u)/com.julienchateau.termiclaude`).

Pour retirer le demarrage automatique :

```bash
bash launchd/uninstall.sh
```

> Le LaunchAgent pointe vers le binaire **dans ce depot**
> (`app/TermiClaude.app/Contents/MacOS/TermiClaude`). Si tu deplaces le depot, relance
> `install.sh` pour reecrire le chemin.
>
> Si `com.julienchateau.hyperclaude` etait deja installe (ancienne version Hyper), retire-le
> d'abord : `launchctl bootout gui/$(id -u)/com.julienchateau.hyperclaude 2>/dev/null; rm -f
> ~/Library/LaunchAgents/com.julienchateau.hyperclaude.plist` - puis relance `install.sh`
> ci-dessus pour enregistrer le nouveau label `com.julienchateau.termiclaude`.

## Regenerer les icones

Les PNG/icns proviennent des SVG de `assets/`, rasterises par `tools/svg2png.swift`
(WKWebView, fond transparent, plein cadre - `qlmanage` ajoutait un fond blanc). Voir
l'entete du fichier pour la commande (compilation + usage), puis reconstruire l'iconset
via `iconutil` et relancer `app/build.sh`.

## Tests

```bash
python3 -m unittest discover -s tests -v   # stdlib uniquement, aucune dependance
```

## Contraintes

- **Lecture seule** de `~/.claude` : aucun hook, aucune modification de configuration.
- **stdlib uniquement** pour le socle (aucune dependance runtime).
- Python 3.9+.
