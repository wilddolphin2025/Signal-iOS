#!/usr/bin/env python3
"""Patch a checkout of visigoth/signal-call-tunnel for echo calls."""

from pathlib import Path
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/signal-call-tunnel")
main_path = root / "signal-call-tunnel/src/main.rs"
control_path = root / "signal-call-tunnel/src/control.rs"
main = main_path.read_text()
control = control_path.read_text()

if "struct EchoVideoSink" not in main:
    main = main.replace(
        "media::{VideoFrame, VideoSink},",
        "media::{VideoFrame, VideoPixelFormat, VideoSink, VideoSource},",
        1,
    )
    start = main.find("/// Dummy video sink")
    end = main.find("/// Dummy HTTP client")
    if start < 0 or end < 0:
        raise SystemExit(f"video sink block not found ({start}, {end})")
    main = (
        main[:start]
        + """/// Sends each remote video frame back out on the local video track.
struct EchoVideoSink {
    source: VideoSource,
}

impl VideoSink for EchoVideoSink {
    fn on_video_frame(&self, _demux_id: u32, frame: VideoFrame) {
        let frame = frame.apply_rotation();
        let width = frame.width();
        let height = frame.height();
        if width == 0 || height == 0 {
            return;
        }
        if let Some(i420) = frame.as_i420() {
            let echoed = VideoFrame::copy_from_slice(width, height, VideoPixelFormat::I420, i420);
            self.source.push_frame(echoed);
            return;
        }
        let mut rgba = vec![0u8; (width as usize) * (height as usize) * 4];
        frame.to_rgba(&mut rgba);
        let echoed = VideoFrame::copy_from_slice(width, height, VideoPixelFormat::Rgba, &rgba);
        self.source.push_frame(echoed);
    }

    fn box_clone(&self) -> Box<dyn VideoSink> {
        Box::new(EchoVideoSink {
            source: self.source.clone(),
        })
    }
}

"""
        + main[end:]
    )
    old_offer = "signaling::Offer::new(CallMediaType::Audio, opaque)"
    new_offer = """signaling::Offer::new(
                if opaque.windows(7).any(|window| window == b"m=video") {
                    CallMediaType::Video
                } else {
                    CallMediaType::Audio
                },
                opaque,
            )"""
    if old_offer not in main:
        raise SystemExit("audio offer constructor not found")
    main = main.replace(old_offer, new_offer, 1)
    old_sink = "Box::new(NullVideoSink),"
    if old_sink not in main:
        raise SystemExit("NullVideoSink use not found")
    main = main.replace(
        old_sink,
        "Box::new(EchoVideoSink { source: outgoing_video_source.clone() }),",
        1,
    )
    main = main.replace(
        "ControlMessage::ReceivedIce { candidates } => {",
        "ControlMessage::ReceivedIce {\n                candidates,\n                sender_device_id,\n            } => {",
        1,
    )
    main = main.replace(
        "sender_device_id: 1 as DeviceId,",
        "sender_device_id,",
        1,
    )

if "sender_device_id: u32" not in control.split("enum ControlMessage")[1].split("Accept,")[0]:
    control = control.replace(
        "ReceivedIce { candidates: Vec<Vec<u8>> },",
        "ReceivedIce { candidates: Vec<Vec<u8>>, sender_device_id: u32 },",
        1,
    )
    old = '''            Ok(ControlMessage::ReceivedIce { candidates })'''
    new = '''            Ok(ControlMessage::ReceivedIce {
                candidates,
                sender_device_id,
            })'''
    if old not in control:
        raise SystemExit("ReceivedIce constructor not found")
    # Insert sender_device_id extraction before the candidates parse in receivedIce only.
    needle = '''        "receivedIce" => {
            let candidates = if let Some(arr) = v["candidates"].as_array() {'''
    insert = '''        "receivedIce" => {
            let sender_device_id = v["senderDeviceId"].as_u64().unwrap_or(1) as u32;
            let candidates = if let Some(arr) = v["candidates"].as_array() {'''
    if needle not in control:
        raise SystemExit("receivedIce parser not found")
    control = control.replace(needle, insert, 1)
    control = control.replace(
        '''                    let b64 = c.as_str()?;
                    BASE64.decode(b64).ok()''',
        '''                    let b64 = c
                        .as_str()
                        .or_else(|| c.get("opaque").and_then(|value| value.as_str()))?;
                    BASE64.decode(b64).ok()''',
        1,
    )
    if control.count(old) != 1:
        raise SystemExit(f"expected one ReceivedIce constructor, found {control.count(old)}")
    control = control.replace(old, new, 1)
    control = control.replace(
        "ControlMessage::ReceivedIce { candidates } => {",
        "ControlMessage::ReceivedIce { candidates, sender_device_id: _ } => {",
    )

main_path.write_text(main)
control_path.write_text(control)
print("patched", main_path)
print("patched", control_path)
