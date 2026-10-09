#!/usr/bin/env python3
"""Signal / WebRTC test gateway for rtc.wilddolphin.us.

Exposes four dialable test contacts:
  echo, videoecho, prerecorded, recordandplayback
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import ssl
import time
import uuid
from pathlib import Path
from typing import Any

from aiohttp import WSMsgType, web

try:
    from aiortc import RTCPeerConnection, RTCSessionDescription, RTCConfiguration, RTCIceServer
    from aiortc.contrib.media import MediaBlackhole, MediaPlayer, MediaRecorder, MediaRelay

    AIORTC_AVAILABLE = True
except ImportError:  # pragma: no cover - optional at unit-test time
    AIORTC_AVAILABLE = False
    RTCPeerConnection = None  # type: ignore
    RTCSessionDescription = None  # type: ignore
    RTCConfiguration = None  # type: ignore
    RTCIceServer = None  # type: ignore
    MediaBlackhole = MediaPlayer = MediaRecorder = MediaRelay = None  # type: ignore

ROOT = Path(__file__).resolve().parent
CONTACTS_PATH = ROOT / "contacts.json"
WEB_DIR = ROOT / "web"
MEDIA_DIR = ROOT / "media"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8787
RECORD_SECONDS = 8.0

log = logging.getLogger("signal-gateway")


def load_contacts(path: Path = CONTACTS_PATH) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    if "contacts" not in data or not data["contacts"]:
        raise ValueError("contacts.json must contain a contacts array")
    ids = [c["id"] for c in data["contacts"]]
    if len(ids) != len(set(ids)):
        raise ValueError("contact ids must be unique")
    return data


def contact_by_id(catalog: dict[str, Any], contact_id: str) -> dict[str, Any] | None:
    for contact in catalog["contacts"]:
        if contact["id"] == contact_id:
            return contact
    return None


def contact_by_number(catalog: dict[str, Any], number: str) -> dict[str, Any] | None:
    compact = "".join(ch for ch in number if ch.isdigit() or ch == "+")
    for contact in catalog["contacts"]:
        if number in (contact["id"], contact["e164"], contact["short_number"]):
            return contact
        if compact and compact in (contact["e164"], contact["short_number"]):
            return contact
        if compact and contact["e164"].endswith(compact) and len(compact) >= 4:
            return contact
    return None


def ice_servers(catalog: dict[str, Any]) -> list[Any]:
    if not AIORTC_AVAILABLE:
        return []
    servers: list[Any] = []
    for entry in catalog.get("turn", []):
        urls = entry.get("urls") or []
        servers.append(
            RTCIceServer(
                urls=urls,
                username=entry.get("username"),
                credential=entry.get("credential"),
            )
        )
    if not servers:
        servers.append(RTCIceServer(urls=["stun:stun.l.google.com:19302"]))
    return servers


def media_paths() -> dict[str, Path]:
    return {
        "prerecorded_audio": MEDIA_DIR / "prerecorded.wav",
        "prerecorded_video": MEDIA_DIR / "prerecorded.mp4",
        "tone": MEDIA_DIR / "tone.wav",
    }


def pick_prerecorded() -> Path | None:
    paths = media_paths()
    for key in ("prerecorded_video", "prerecorded_audio", "tone"):
        if paths[key].is_file():
            return paths[key]
    return None


class CallSession:
    def __init__(self, contact: dict[str, Any], catalog: dict[str, Any]) -> None:
        if not AIORTC_AVAILABLE:
            raise RuntimeError("aiortc is not installed")
        self.contact = contact
        self.pc = RTCPeerConnection(RTCConfiguration(iceServers=ice_servers(catalog)))
        self.relay = MediaRelay()
        self.recorder: Any = None
        self.player: Any = None
        self.blackhole = MediaBlackhole()
        self.record_path = MEDIA_DIR / "recordings" / f"{contact['id']}-{uuid.uuid4().hex}.mp4"
        self._playback_task: asyncio.Task[None] | None = None

    async def attach_track(self, track: Any) -> None:
        kind = self.contact["id"]
        if kind in ("echo", "videoecho"):
            if kind == "echo" and track.kind == "video":
                await self.blackhole.start()
                self.blackhole.addTrack(track)
                return
            self.pc.addTrack(self.relay.subscribe(track))
            return
        if kind == "prerecorded":
            await self.blackhole.start()
            self.blackhole.addTrack(track)
            return
        if kind == "recordandplayback":
            self.record_path.parent.mkdir(parents=True, exist_ok=True)
            if self.recorder is None:
                self.recorder = MediaRecorder(str(self.record_path))
                await self.recorder.start()
            self.recorder.addTrack(track)
            if self._playback_task is None:
                self._playback_task = asyncio.create_task(self._record_then_play())

    async def add_prerecorded(self) -> None:
        if self.contact["id"] != "prerecorded":
            return
        path = pick_prerecorded()
        if path is None:
            log.warning("No prerecorded media found under %s", MEDIA_DIR)
            return
        self.player = MediaPlayer(str(path))
        if self.player.audio:
            self.pc.addTrack(self.player.audio)
        if self.player.video and self.contact.get("wants_video"):
            self.pc.addTrack(self.player.video)

    async def _record_then_play(self) -> None:
        await asyncio.sleep(RECORD_SECONDS)
        if self.recorder is not None:
            await self.recorder.stop()
            self.recorder = None
        if not self.record_path.is_file():
            return
        self.player = MediaPlayer(str(self.record_path))
        if self.player.audio:
            self.pc.addTrack(self.player.audio)
        if self.player.video and self.contact.get("wants_video"):
            self.pc.addTrack(self.player.video)

    async def close(self) -> None:
        if self._playback_task:
            self._playback_task.cancel()
        if self.recorder is not None:
            await self.recorder.stop()
        if self.player is not None:
            if self.player.audio:
                self.player.audio.stop()
            if self.player.video:
                self.player.video.stop()
        await self.blackhole.stop()
        await self.pc.close()


def build_app(catalog: dict[str, Any]) -> web.Application:
    app = web.Application()
    app["catalog"] = catalog
    app["sessions"]: dict[str, CallSession] = {}
    app.router.add_get("/health", handle_health)
    app.router.add_get("/contacts", handle_contacts)
    app.router.add_get("/contacts/{key}", handle_contact)
    app.router.add_get("/call/{contact_id}", handle_call_page)
    app.router.add_get("/ws/{contact_id}", handle_ws)
    app.router.add_get("/", handle_index)
    app.router.add_static("/static", WEB_DIR, show_index=False)
    return app


def _json_response(data: Any, status: int = 200) -> web.Response:
    return web.json_response(data, status=status)


def signal_contact(contact: dict[str, Any]) -> dict[str, Any]:
    payload = dict(contact)
    payload["registered"] = True
    payload.setdefault("system", "signal")
    return payload


async def handle_health(request: web.Request) -> web.Response:
    catalog = request.app["catalog"]
    return _json_response(
        {
            "ok": True,
            "service": "signal-gateway",
            "host": catalog.get("host"),
            "aiortc": AIORTC_AVAILABLE,
            "contacts": [c["id"] for c in catalog["contacts"]],
            "registered": [c["e164"] for c in catalog["contacts"]],
            "time": int(time.time()),
        }
    )


async def handle_contacts(request: web.Request) -> web.Response:
    catalog = request.app["catalog"]
    return _json_response(
        {
            **catalog,
            "contacts": [signal_contact(contact) for contact in catalog["contacts"]],
        }
    )


async def handle_contact(request: web.Request) -> web.Response:
    catalog = request.app["catalog"]
    key = request.match_info["key"]
    contact = contact_by_id(catalog, key) or contact_by_number(catalog, key)
    if contact is None:
        return _json_response({"error": "unknown contact", "key": key}, status=404)
    return _json_response(signal_contact(contact))


async def handle_index(request: web.Request) -> web.Response:
    return web.FileResponse(WEB_DIR / "index.html")


async def handle_call_page(request: web.Request) -> web.Response:
    catalog = request.app["catalog"]
    contact_id = request.match_info["contact_id"]
    if contact_by_id(catalog, contact_id) is None:
        return _json_response({"error": "unknown contact", "id": contact_id}, status=404)
    return web.FileResponse(WEB_DIR / "call.html")


async def handle_ws(request: web.Request) -> web.WebSocketResponse:
    catalog = request.app["catalog"]
    contact_id = request.match_info["contact_id"]
    contact = contact_by_id(catalog, contact_id)
    if contact is None:
        raise web.HTTPNotFound(text=json.dumps({"error": "unknown contact"}))

    ws = web.WebSocketResponse(heartbeat=30.0)
    await ws.prepare(request)
    session: CallSession | None = None
    session_id = uuid.uuid4().hex

    await ws.send_json(
        {
            "type": "welcome",
            "contact": contact,
            "iceServers": catalog.get("turn", []),
            "aiortc": AIORTC_AVAILABLE,
        }
    )

    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                payload = json.loads(msg.data)
            except json.JSONDecodeError:
                await ws.send_json({"type": "error", "error": "invalid json"})
                continue
            kind = payload.get("type")
            if kind == "join":
                await ws.send_json({"type": "joined", "contact": contact})
            elif kind == "offer":
                if not AIORTC_AVAILABLE:
                    await ws.send_json(
                        {
                            "type": "error",
                            "error": "media engine unavailable (aiortc not installed)",
                        }
                    )
                    continue
                session = CallSession(contact, catalog)
                request.app["sessions"][session_id] = session

                @session.pc.on("track")
                def on_track(track: Any, bound=session) -> None:
                    log.info("track %s for %s", track.kind, bound.contact["id"])
                    asyncio.create_task(bound.attach_track(track))

                @session.pc.on("iceconnectionstatechange")
                def on_ice(bound=session) -> None:
                    log.info("ice %s", bound.pc.iceConnectionState)

                await session.add_prerecorded()
                offer = RTCSessionDescription(sdp=payload["sdp"], type=payload.get("sdpType", "offer"))
                await session.pc.setRemoteDescription(offer)
                answer = await session.pc.createAnswer()
                await session.pc.setLocalDescription(answer)
                await ws.send_json(
                    {
                        "type": "answer",
                        "sdp": session.pc.localDescription.sdp,
                        "sdpType": session.pc.localDescription.type,
                    }
                )
            elif kind == "ice" and session is not None:
                candidate = payload.get("candidate")
                if candidate:
                    await session.pc.addIceCandidate(candidate)
            elif kind in ("hangup", "bye") and session is not None:
                await session.close()
                session = None
                await ws.send_json({"type": "ended"})
    finally:
        if session is not None:
            await session.close()
        request.app["sessions"].pop(session_id, None)
    return ws


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Signal WebRTC test gateway")
    parser.add_argument("--host", default=os.environ.get("SIGNAL_GATEWAY_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SIGNAL_GATEWAY_PORT", DEFAULT_PORT)))
    parser.add_argument("--contacts", default=str(CONTACTS_PATH))
    parser.add_argument("--tls-cert", default=os.environ.get("SIGNAL_GATEWAY_TLS_CERT", ""))
    parser.add_argument("--tls-key", default=os.environ.get("SIGNAL_GATEWAY_TLS_KEY", ""))
    return parser.parse_args(argv)


async def main(argv: list[str] | None = None) -> None:
    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
    args = parse_args(argv)
    catalog = load_contacts(Path(args.contacts))
    app = build_app(catalog)
    ssl_context = None
    if args.tls_cert and args.tls_key:
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.load_cert_chain(args.tls_cert, args.tls_key)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, args.host, args.port, ssl_context=ssl_context)
    await site.start()
    log.info(
        "signal-gateway listening on %s:%s contacts=%s aiortc=%s",
        args.host,
        args.port,
        [c["id"] for c in catalog["contacts"]],
        AIORTC_AVAILABLE,
    )
    while True:
        await asyncio.sleep(3600)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
