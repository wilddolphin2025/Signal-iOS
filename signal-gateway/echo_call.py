#!/usr/bin/env python3
"""Accept incoming Signal calls on signal-cli and echo the caller's media.

Audio is looped with PulseAudio. Video frames are echoed inside signal-call-tunnel.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import subprocess
import time
from typing import Any

log = logging.getLogger("echo-call")

ACCOUNT = os.environ["SIGNAL_CLI_ACCOUNT"]
TCP_HOST = os.environ.get("SIGNAL_CLI_TCP_HOST", "127.0.0.1")
TCP_PORT = int(os.environ.get("SIGNAL_CLI_TCP_PORT", "7584"))


def pulse(*args: str) -> str:
    env = os.environ.copy()
    env.setdefault("XDG_RUNTIME_DIR", "/run/signal-gateway")
    return subprocess.check_output(["pactl", *args], text=True, env=env).strip()


def pulse_devices(input_name: str, output_name: str) -> tuple[str, str]:
    sink = input_name if input_name.startswith("sink_for_") else f"sink_for_{input_name}"
    source = output_name if output_name.endswith(".monitor") else f"{output_name}.monitor"
    return source, sink


class EchoCallClient:
    def __init__(self) -> None:
        self._id = 0
        self._sock: socket.socket | None = None
        self._buf = b""
        self._loops: dict[str, str] = {}
        self._accepted: set[str] = set()

    def connect(self) -> None:
        sock = socket.create_connection((TCP_HOST, TCP_PORT), timeout=10)
        sock.settimeout(None)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        self._sock = sock
        self._buf = b""
        sub = self.request("subscribeCallEvents", {"account": ACCOUNT})
        log.info("subscribed to call events: %s", sub)

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        self._id += 1
        request_id = str(self._id)
        payload = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params or {},
        }
        self._send(payload)
        while True:
            message = self._read_message()
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result")
            self.handle_message(message)

    def serve_forever(self) -> None:
        while True:
            try:
                if self._sock is None:
                    self.connect()
                message = self._read_message()
            except (OSError, TimeoutError, json.JSONDecodeError) as exc:
                log.warning("signal-cli connection lost: %s", exc)
                self.close()
                time.sleep(2)
                continue
            self.handle_message(message)

    def handle_message(self, message: dict[str, Any]) -> None:
        if message.get("method") != "callEvent":
            return
        params = message.get("params") or {}
        event = params.get("result") or params
        if not isinstance(event, dict):
            return
        state = event.get("state")
        call_id = event.get("callId")
        if call_id is None:
            return
        call_key = str(call_id)
        log.info(
            "call %s state=%s video_devices=%s/%s",
            call_key,
            state,
            event.get("inputDeviceName"),
            event.get("outputDeviceName"),
        )
        if state == "RINGING_INCOMING" and not event.get("isOutgoing") and call_key not in self._accepted:
            self._accepted.add(call_key)
            try:
                result = self.request("acceptCall", {"account": ACCOUNT, "callId": call_id})
                log.info("accepted call %s: %s", call_key, result)
                if isinstance(result, dict):
                    event = {**event, **result}
            except Exception:
                self._accepted.discard(call_key)
                log.exception("acceptCall failed for %s", call_key)
                return
        if state in {"RINGING_INCOMING", "CONNECTING", "CONNECTED"}:
            self.ensure_audio_echo(call_key, event)
        if state == "ENDED":
            self.stop_audio_echo(call_key)
            self._accepted.discard(call_key)

    def ensure_audio_echo(self, call_key: str, event: dict[str, Any]) -> None:
        if call_key in self._loops:
            return
        input_name = event.get("inputDeviceName")
        output_name = event.get("outputDeviceName")
        if not input_name or not output_name:
            return
        source, sink = pulse_devices(str(input_name), str(output_name))
        for _ in range(50):
            sinks = pulse("list", "short", "sinks")
            sources = pulse("list", "short", "sources")
            if sink in sinks and source in sources:
                break
            time.sleep(0.1)
        else:
            log.warning("pulse devices not ready for call %s (%s -> %s)", call_key, source, sink)
            return
        module_id = pulse(
            "load-module",
            "module-loopback",
            f"source={source}",
            f"sink={sink}",
            "latency_msec=20",
        )
        self._loops[call_key] = module_id
        log.info("audio echo %s: %s -> %s (module %s)", call_key, source, sink, module_id)

    def stop_audio_echo(self, call_key: str) -> None:
        module_id = self._loops.pop(call_key, None)
        if not module_id:
            return
        try:
            pulse("unload-module", module_id)
        except subprocess.CalledProcessError:
            log.warning("failed to unload loopback %s", module_id)

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def _send(self, payload: dict[str, Any]) -> None:
        if self._sock is None:
            raise OSError("not connected")
        self._sock.sendall((json.dumps(payload) + "\n").encode())

    def _read_message(self) -> dict[str, Any]:
        if self._sock is None:
            raise OSError("not connected")
        while b"\n" not in self._buf:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise OSError("socket closed")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        if not line.strip():
            return self._read_message()
        message = json.loads(line.decode())
        if not isinstance(message, dict):
            raise json.JSONDecodeError("expected object", line.decode(), 0)
        return message


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)s %(message)s")
    EchoCallClient().serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
