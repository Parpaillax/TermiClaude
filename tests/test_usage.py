"""Tests du lecteur d'usage (footer, derisquage).

Stdlib uniquement (``unittest``, ``unittest.mock``). Aucune connexion reseau ni Keychain :
tout est mocke. L'echantillon `SAMPLE` reproduit la reponse reelle de /api/oauth/usage.

    python3 -m unittest discover -s tests
"""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from hyperclaude import usage  # noqa: E402

# Reponse reelle observee (2026-07-15), reduite aux champs pertinents + tableau limits.
SAMPLE = {
    "five_hour": {"utilization": 22.0, "resets_at": "2026-07-15T18:39:59+00:00"},
    "seven_day": {"utilization": 23.0, "resets_at": "2026-07-18T21:59:59+00:00"},
    "limits": [
        {"kind": "session", "group": "session", "percent": 22, "severity": "normal",
         "resets_at": "2026-07-15T18:39:59+00:00", "is_active": False},
        {"kind": "weekly_all", "group": "weekly", "percent": 23, "severity": "normal",
         "resets_at": "2026-07-18T21:59:59+00:00", "is_active": True},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
         "resets_at": None, "scope": {"model": {"display_name": "Fable"}}, "is_active": False},
    ],
}


class ParseUsageTests(unittest.TestCase):
    def test_parses_limits_array(self):
        snap = usage.parse_usage(SAMPLE)
        self.assertTrue(snap.available)
        self.assertEqual(snap.session_percent, 22.0)
        self.assertEqual(snap.weekly_percent, 23.0)  # weekly_all = hors Fable
        self.assertEqual(snap.session_severity, "normal")
        self.assertEqual(snap.weekly_severity, "normal")
        self.assertTrue(snap.weekly_resets_at.startswith("2026-07-18"))

    def test_fallback_on_windows_when_no_limits(self):
        data = {"five_hour": {"utilization": 40}, "seven_day": {"utilization": 55}}
        snap = usage.parse_usage(data)
        self.assertTrue(snap.available)
        self.assertEqual(snap.session_percent, 40.0)
        self.assertEqual(snap.weekly_percent, 55.0)

    def test_unavailable_when_empty(self):
        snap = usage.parse_usage({})
        self.assertFalse(snap.available)
        self.assertIsNotNone(snap.error)

    def test_ignores_weekly_scoped_fable(self):
        # Seul weekly_all doit alimenter le %, pas la limite scopee Fable.
        snap = usage.parse_usage(SAMPLE)
        self.assertEqual(snap.weekly_percent, 23.0)


class ReadTokenTests(unittest.TestCase):
    def test_reads_access_token(self):
        blob = '{"claudeAiOauth": {"accessToken": "sk-xxx", "expiresAt": 123}}'
        fake = mock.Mock(returncode=0, stdout=blob)
        with mock.patch.object(usage.subprocess, "run", return_value=fake):
            token, exp = usage.read_token()
        self.assertEqual(token, "sk-xxx")
        self.assertEqual(exp, 123)

    def test_missing_item_returns_none(self):
        fake = mock.Mock(returncode=44, stdout="")
        with mock.patch.object(usage.subprocess, "run", return_value=fake):
            self.assertEqual(usage.read_token(), (None, None))

    def test_corrupt_blob_returns_none(self):
        fake = mock.Mock(returncode=0, stdout="not json")
        with mock.patch.object(usage.subprocess, "run", return_value=fake):
            self.assertEqual(usage.read_token(), (None, None))


class GetUsageTests(unittest.TestCase):
    def test_no_token_is_unavailable(self):
        with mock.patch.object(usage, "read_token", return_value=(None, None)):
            snap = usage.get_usage()
        self.assertFalse(snap.available)
        self.assertIn("token", snap.error)

    def test_http_401_is_unavailable(self):
        import urllib.error
        err = urllib.error.HTTPError(usage.USAGE_URL, 401, "Unauthorized", {}, None)
        with mock.patch.object(usage, "read_token", return_value=("tok", None)), \
             mock.patch.object(usage, "fetch_usage", side_effect=err):
            snap = usage.get_usage()
        self.assertFalse(snap.available)
        self.assertIn("expire", snap.error)

    def test_happy_path(self):
        with mock.patch.object(usage, "read_token", return_value=("tok", None)), \
             mock.patch.object(usage, "fetch_usage", return_value=SAMPLE):
            snap = usage.get_usage()
        self.assertTrue(snap.available)
        self.assertEqual((snap.session_percent, snap.weekly_percent), (22.0, 23.0))


if __name__ == "__main__":
    unittest.main()
