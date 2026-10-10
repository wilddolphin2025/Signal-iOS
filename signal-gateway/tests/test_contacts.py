#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
CONTACTS = json.loads((ROOT / "contacts.json").read_text())
SWIFT = (REPO / "SignalServiceKit" / "Calls" / "SignalGatewayContacts.swift").read_text()


class ContactCatalogTests(unittest.TestCase):
    def test_required_functions(self) -> None:
        ids = [c["id"] for c in CONTACTS["contacts"]]
        self.assertEqual(ids, ["echo", "videoecho", "prerecorded", "recordandplayback"])

    def test_unique_numbers(self) -> None:
        e164s = [c["e164"] for c in CONTACTS["contacts"]]
        shorts = [c["short_number"] for c in CONTACTS["contacts"]]
        self.assertEqual(len(e164s), len(set(e164s)))
        self.assertEqual(len(shorts), len(set(shorts)))
        for e164 in e164s:
            self.assertTrue(re.fullmatch(r"\+[1-9][0-9]{7,14}", e164), e164)

    def test_signal_registration_fields(self) -> None:
        expected = [
            ("echo", "Echo", "+15551111001", "1001"),
            ("videoecho", "Video Echo", "+15551111002", "1002"),
            ("prerecorded", "Prerecorded", "+15551111003", "1003"),
            ("recordandplayback", "Record and Playback", "+15551111004", "1004"),
        ]
        actual = [
            (c["id"], c["display_name"], c["e164"], c["short_number"])
            for c in CONTACTS["contacts"]
        ]
        self.assertEqual(actual, expected)
        for contact in CONTACTS["contacts"]:
            self.assertTrue(contact["registered"])
            self.assertTrue(contact["aci"])
            self.assertTrue(contact["pni"])
            self.assertNotEqual(contact["aci"], contact["pni"])

    def test_swift_catalog_stays_in_sync(self) -> None:
        for contact in CONTACTS["contacts"]:
            self.assertIn(f'id: "{contact["id"]}"', SWIFT)
            self.assertIn(f'e164: "{contact["e164"]}"', SWIFT)
            self.assertIn(f'shortNumber: "{contact["short_number"]}"', SWIFT)
            self.assertIn(f'displayName: "{contact["display_name"]}"', SWIFT)
            self.assertIn(contact["aci"], SWIFT)
            self.assertIn(contact["pni"], SWIFT)

    def test_host(self) -> None:
        self.assertEqual(CONTACTS["host"], "rtc.wilddolphin.us")
        self.assertIn("rtc.wilddolphin.us", SWIFT)


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)
