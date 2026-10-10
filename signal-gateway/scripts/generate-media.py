#!/usr/bin/env python3
"""Generate a small WAV tone used by the prerecorded contact."""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "media"
SAMPLE_RATE = 8000
DURATION = 4.0
FREQ = 440.0


def main() -> None:
    MEDIA.mkdir(parents=True, exist_ok=True)
    path = MEDIA / "prerecorded.wav"
    nframes = int(SAMPLE_RATE * DURATION)
    with wave.open(str(path), "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        frames = bytearray()
        for i in range(nframes):
            t = i / SAMPLE_RATE
            # Two-tone "this is a test" style beep pattern.
            freq = FREQ if int(t * 2) % 2 == 0 else 660.0
            sample = int(16000 * math.sin(2 * math.pi * freq * t))
            frames.extend(struct.pack("<h", sample))
        wav.writeframes(frames)
    (MEDIA / "tone.wav").write_bytes(path.read_bytes())
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
