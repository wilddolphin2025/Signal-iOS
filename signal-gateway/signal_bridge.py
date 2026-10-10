#!/usr/bin/env python3
"""JSON-RPC bridge between signal-cli and the RTC test-contact directory.

Incoming Signal messages receive the gateway contact list. Optional future
call events from signal-cli are acknowledged with the matching extension.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
CONTACTS_PATH = ROOT / "contacts.json"
log = logging.getLogger("signal-bridge")


def load_contacts(path: Path = CONTACTS_PATH) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def directory_text(catalog: dict[str, Any]) -> str:
    host = catalog.get("host", "rtc.wilddolphin.us")
    lines = [
        "Wild Dolphin Signal gateway",
        f"Host: {host}",
        "",
        "Dial these test contacts from Signal:",
    ]
    for contact in catalog["contacts"]:
        lines.append(
            f"- {contact['display_name']}  {contact['e164']}  (ext {contact['short_number']})  {contact['id']}"
        )
        lines.append(f"  {contact['summary']}")
    lines.extend(
        [
            "",
            "Reply with echo, videoecho, prerecorded, or recordandplayback for one contact.",
            "Reply with help for this directory.",
        ]
    )
    return "\n".join(lines)


def lookup_contact(catalog: dict[str, Any], text: str) -> dict[str, Any] | None:
    q = (text or "").strip().lower()
    if not q:
        return None
    for contact in catalog["contacts"]:
        if q in {
            contact["id"],
            contact["display_name"].lower(),
            contact["e164"],
            contact["short_number"],
        }:
            return contact
        if q.replace(" ", "") == contact["id"]:
            return contact
    return None


class SignalCliRpc:
    def __init__(self, endpoint: str, account: str) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.account = account
        self._id = 0

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": str(self._id), "method": method, "params": params or {}}
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.endpoint,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
        if "error" in body:
            raise RuntimeError(body["error"])
        return body.get("result")

    def send(self, recipient: str, message: str) -> None:
        params: dict[str, Any] = {"recipient": [recipient], "message": message}
        if self.account:
            params["account"] = self.account
        self.call("send", params)


def extract_messages(event: dict[str, Any]) -> list[tuple[str, str]]:
    envelope = event.get("envelope") or event.get("params", {}).get("envelope") or event
    data_message = envelope.get("dataMessage") or {}
    source = envelope.get("sourceNumber") or envelope.get("source") or envelope.get("sourceName")
    text = data_message.get("message") or ""
    if source and text:
        return [(str(source), str(text))]
    return []


def reply_for(catalog: dict[str, Any], text: str) -> str:
    lowered = text.strip().lower()
    if lowered in {"help", "contacts", "directory", "hi", "hello", "start"}:
        return directory_text(catalog)
    contact = lookup_contact(catalog, text)
    if contact:
        return (
            f"{contact['display_name']}  {contact['e164']}  ext {contact['short_number']}\n"
            f"{contact['summary']}\n"
            f"Open https://{catalog.get('host', 'rtc.wilddolphin.us')}/call/{contact['id']}"
        )
    return directory_text(catalog)


def handle_event(rpc: SignalCliRpc, catalog: dict[str, Any], event: dict[str, Any]) -> None:
    for source, text in extract_messages(event):
        log.info("message from %s: %s", source, text[:80])
        rpc.send(source, reply_for(catalog, text))


def poll_receive_loop(rpc: SignalCliRpc, catalog: dict[str, Any]) -> None:
    while True:
        try:
            result = rpc.call("receive", {"timeout": 5, "account": rpc.account} if rpc.account else {"timeout": 5})
            events = result if isinstance(result, list) else [result] if result else []
            for event in events:
                if isinstance(event, dict):
                    handle_event(rpc, catalog, event)
        except urllib.error.URLError as exc:
            log.warning("signal-cli rpc unreachable: %s", exc)
            time.sleep(3)
        except Exception as exc:  # noqa: BLE001 - keep daemon alive
            log.exception("bridge loop error: %s", exc)
            time.sleep(1)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="signal-cli directory bridge")
    parser.add_argument(
        "--rpc",
        default=os.environ.get("SIGNAL_CLI_RPC", "http://127.0.0.1:7583/api/v1/rpc"),
    )
    parser.add_argument("--account", default=os.environ.get("SIGNAL_CLI_ACCOUNT", ""))
    parser.add_argument("--contacts", default=str(CONTACTS_PATH))
    parser.add_argument("--once", action="store_true", help="Print directory and exit")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
    args = parse_args(argv)
    catalog = load_contacts(Path(args.contacts))
    if args.once:
        print(directory_text(catalog))
        return 0
    if not args.account:
        print(directory_text(catalog))
        log.info("No SIGNAL_CLI_ACCOUNT set; waiting. Link an account to enable replies.")
        while True:
            time.sleep(3600)
    rpc = SignalCliRpc(args.rpc, args.account)
    poll_receive_loop(rpc, catalog)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
