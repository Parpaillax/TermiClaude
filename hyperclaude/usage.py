"""Lecture de l'usage de quota Claude Code (session + semaine tous modeles).

Derisquage du footer d'usage : source confirmee (voir le CdC `hyper_claude_mac_widget`).

  - Endpoint : GET https://api.anthropic.com/api/oauth/usage
      headers : Authorization: Bearer <token>, anthropic-beta: oauth-2025-04-20
  - Token   : Keychain macOS, service "Claude Code-credentials",
      blob JSON -> claudeAiOauth.accessToken (+ expiresAt).
  - Reponse : tableau `limits` avec, notamment :
      kind="session"    -> % de la session courante (fenetre 5 h)
      kind="weekly_all" -> % hebdomadaire tous modeles, HORS Fable
      kind="weekly_scoped" (scope.model = Fable) -> limite Fable, suivie a part.
    Repli sur `five_hour.utilization` / `seven_day.utilization` si `limits` absent.

Principes : stdlib uniquement, aucune ecriture, jamais de log du token ni de la reponse
brute. En cas d'echec (token absent/expire, reseau, format), l'usage est marque
indisponible - jamais de valeur inventee.
"""

from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from typing import Optional, Tuple

KEYCHAIN_SERVICE = "Claude Code-credentials"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA = "oauth-2025-04-20"
TIMEOUT_S = 6


@dataclass
class UsageSnapshot:
    """Instantane d'usage pret pour l'affichage."""

    available: bool = False
    session_percent: Optional[float] = None
    weekly_percent: Optional[float] = None
    session_resets_at: Optional[str] = None
    weekly_resets_at: Optional[str] = None
    session_severity: Optional[str] = None
    weekly_severity: Optional[str] = None
    error: Optional[str] = None

    def to_dict(self) -> dict:
        return asdict(self)


def read_token() -> Tuple[Optional[str], Optional[int]]:
    """Retourne (accessToken, expiresAt_ms) depuis le Keychain, ou (None, None).

    N'affiche jamais le token. Une autorisation Keychain macOS peut etre demandee au
    binaire appelant lors du premier acces.
    """
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None, None
    if out.returncode != 0 or not out.stdout.strip():
        return None, None
    try:
        blob = json.loads(out.stdout)
    except ValueError:
        return None, None
    oauth = blob.get("claudeAiOauth") if isinstance(blob, dict) else None
    if not isinstance(oauth, dict):
        return None, None
    return oauth.get("accessToken"), oauth.get("expiresAt")


def fetch_usage(token: str) -> dict:
    """Appelle l'endpoint d'usage et retourne le JSON decode. Leve en cas d'erreur."""
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": OAUTH_BETA,
            "Accept": "application/json",
        },
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _percent(value) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_usage(data: dict) -> UsageSnapshot:
    """Extrait session (%) et semaine tous-modeles-hors-Fable (%) de la reponse.

    Prefere le tableau `limits` (canonique, porte la severite) ; repli sur les fenetres
    `five_hour` / `seven_day`.
    """
    snap = UsageSnapshot(available=False)
    if not isinstance(data, dict):
        snap.error = "reponse inattendue"
        return snap

    # Voie privilegiee : tableau `limits`.
    for item in data.get("limits") or []:
        if not isinstance(item, dict):
            continue
        kind = item.get("kind")
        if kind == "session":
            snap.session_percent = _percent(item.get("percent"))
            snap.session_resets_at = item.get("resets_at")
            snap.session_severity = item.get("severity")
        elif kind == "weekly_all":
            snap.weekly_percent = _percent(item.get("percent"))
            snap.weekly_resets_at = item.get("resets_at")
            snap.weekly_severity = item.get("severity")

    # Repli sur les fenetres nommees si `limits` n'a rien donne.
    if snap.session_percent is None:
        fh = data.get("five_hour")
        if isinstance(fh, dict):
            snap.session_percent = _percent(fh.get("utilization"))
            snap.session_resets_at = snap.session_resets_at or fh.get("resets_at")
    if snap.weekly_percent is None:
        sd = data.get("seven_day")
        if isinstance(sd, dict):
            snap.weekly_percent = _percent(sd.get("utilization"))
            snap.weekly_resets_at = snap.weekly_resets_at or sd.get("resets_at")

    snap.available = snap.session_percent is not None or snap.weekly_percent is not None
    if not snap.available:
        snap.error = "aucune fenetre d'usage dans la reponse"
    return snap


def get_usage() -> UsageSnapshot:
    """Point d'entree : lit le token, appelle l'endpoint, retourne un instantane.

    Ne leve jamais : toute erreur est capturee en un snapshot `available=False` porteur
    d'un motif dans `error`.
    """
    token, _expires_at = read_token()
    if not token:
        return UsageSnapshot(available=False, error="token introuvable (Keychain)")
    try:
        data = fetch_usage(token)
    except urllib.error.HTTPError as exc:
        reason = "token expire ou non autorise" if exc.code in (401, 403) else f"HTTP {exc.code}"
        return UsageSnapshot(available=False, error=reason)
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
        return UsageSnapshot(available=False, error=f"appel echoue : {exc.__class__.__name__}")
    return parse_usage(data)


def _main(argv=None) -> int:
    snap = get_usage()
    print(json.dumps(snap.to_dict(), indent=2, ensure_ascii=False))
    return 0 if snap.available else 1


if __name__ == "__main__":
    raise SystemExit(_main())
