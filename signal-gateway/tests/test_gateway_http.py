#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import json
import sys
import unittest
from pathlib import Path

from aiohttp import ClientSession, WSMsgType
from aiohttp.test_utils import AioHTTPTestCase

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from gateway import build_app, load_contacts  # noqa: E402
from signal_bridge import directory_text, lookup_contact, reply_for  # noqa: E402


class GatewayHttpTests(AioHTTPTestCase):
    async def get_application(self):
        return build_app(load_contacts())

    async def test_health_lists_contacts(self) -> None:
        resp = await self.client.get("/health")
        self.assertEqual(resp.status, 200)
        body = await resp.json()
        self.assertTrue(body["ok"])
        self.assertEqual(
            body["contacts"],
            ["echo", "videoecho", "prerecorded", "recordandplayback"],
        )

    async def test_contact_lookup_by_number(self) -> None:
        resp = await self.client.get("/contacts/1002")
        self.assertEqual(resp.status, 200)
        body = await resp.json()
        self.assertEqual(body["id"], "videoecho")
        self.assertEqual(body["e164"], "+15551111002")

    async def test_unknown_contact(self) -> None:
        resp = await self.client.get("/contacts/9999")
        self.assertEqual(resp.status, 404)

    async def test_websocket_welcome(self) -> None:
        async with self.client.ws_connect("/ws/echo") as ws:
            msg = await ws.receive()
            self.assertEqual(msg.type, WSMsgType.TEXT)
            payload = json.loads(msg.data)
            self.assertEqual(payload["type"], "welcome")
            self.assertEqual(payload["contact"]["id"], "echo")
            await ws.send_json({"type": "join"})
            joined = json.loads((await ws.receive()).data)
            self.assertEqual(joined["type"], "joined")


class BridgeTextTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = load_contacts()

    def test_directory_mentions_all_functions(self) -> None:
        text = directory_text(self.catalog)
        for name in ("echo", "videoecho", "prerecorded", "recordandplayback"):
            self.assertIn(name, text)
        self.assertIn("+15551111001", text)

    def test_lookup_and_reply(self) -> None:
        contact = lookup_contact(self.catalog, "1003")
        self.assertIsNotNone(contact)
        self.assertEqual(contact["id"], "prerecorded")
        reply = reply_for(self.catalog, "recordandplayback")
        self.assertIn("+15551111004", reply)


if __name__ == "__main__":
    result = unittest.main(verbosity=2, exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)
