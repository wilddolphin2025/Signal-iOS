#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_enum = "    ReceivedIce { candidates: Vec<Vec<u8>> },"
new_enum = "    ReceivedIce { candidates: Vec<Vec<u8>>, sender_device_id: u32 },"
if old_enum not in text:
    raise SystemExit("enum variant not found")
text = text.replace(old_enum, new_enum, 1)
old_parse = '''        "receivedIce" => {
            let candidates = if let Some(arr) = v["candidates"].as_array() {
                arr.iter()
                    .filter_map(|c| {
                        let b64 = c.as_str()?;
                        BASE64.decode(b64).ok()
                    })
                    .collect()
            } else {
                Vec::new()
            };
            Ok(ControlMessage::ReceivedIce { candidates })
        }'''
new_parse = '''        "receivedIce" => {
            let sender_device_id = v["senderDeviceId"].as_u64().unwrap_or(1) as u32;
            let candidates = if let Some(arr) = v["candidates"].as_array() {
                arr.iter()
                    .filter_map(|c| {
                        let b64 = c
                            .as_str()
                            .or_else(|| c.get("opaque").and_then(|value| value.as_str()))?;
                        BASE64.decode(b64).ok()
                    })
                    .collect()
            } else {
                Vec::new()
            };
            Ok(ControlMessage::ReceivedIce {
                candidates,
                sender_device_id,
            })
        }'''
if old_parse not in text:
    raise SystemExit("parser not found")
text = text.replace(old_parse, new_parse, 1)
text = text.replace(
    "ControlMessage::ReceivedIce { candidates } => {",
    "ControlMessage::ReceivedIce { candidates, sender_device_id: _ } => {",
)
path.write_text(text)
print("updated", path)
