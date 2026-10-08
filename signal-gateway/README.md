# Signal gateway for rtc.wilddolphin.us

WebRTC test contacts a Signal messenger can dial, hosted at
`rtc.wilddolphin.us` (`217.77.3.65`, Ubuntu 24.04).

## Contacts

| Function | Name | E.164 | Extension |
| --- | --- | --- | --- |
| `echo` | Echo | `+15551111001` | 1001 |
| `videoecho` | Video Echo | `+15551111002` | 1002 |
| `prerecorded` | Prerecorded | `+15551111003` | 1003 |
| `recordandplayback` | Record and Playback | `+15551111004` | 1004 |

- **echo** — audio loopback
- **videoecho** — audio + video loopback
- **prerecorded** — plays a short stored clip
- **recordandplayback** — records a few seconds, then plays it back

This Signal iOS fork lists the four contacts in the New Call picker. Dialing
one opens `https://rtc.wilddolphin.us/call/<id>` over WebRTC.

## On the server

SSH with `~/.ssh/id_ed25519` (public key `~/.ssh/id_ed25519.pub`):

```bash
cd signal-gateway
./deploy.sh
```

`deploy.sh` rsyncs this directory to `root@217.77.3.65` and runs `install.sh`,
which installs:

- Python `aiohttp` + `aiortc` media gateway on `127.0.0.1:8787`
- nginx TLS reverse proxy for `rtc.wilddolphin.us`
- [signal-cli](https://github.com/AsamK/signal-cli) JSON-RPC daemon
- optional message bridge that replies with this directory

To attach a real Signal account (so official clients can text the gateway):

```bash
sudo -u signal-gateway signal-cli --data-dir /var/lib/signal-cli link -n rtc-gateway
# scan the QR with Signal → Linked devices
# put the account E.164 or ACI in /etc/signal-gateway.env as SIGNAL_CLI_ACCOUNT
sudo systemctl restart signal-bridge
```

Registering a brand-new number still needs SMS verification (`signal-cli register`
/ `verify`). Linking an existing device does not.

## Local check

```bash
python3 -m pip install aiohttp
python3 signal-gateway/scripts/generate-media.py
python3 signal-gateway/tests/test_contacts.py
python3 signal-gateway/tests/test_gateway_http.py
python3 signal-gateway/gateway.py --host 127.0.0.1 --port 8787
```
