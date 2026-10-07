#!/bin/zsh
# Pulls Signal crash reports and app logs from a connected iPhone, then summarizes the latest crash
# and recent voice-command / AutoSTT activity.
#
#   Signal/AutoSTT/collect-logs.sh [device-udid] [bundle-id]
#
# Output goes to ~/Desktop/SignalLogs/<timestamp>/ (crashes/, logs/, summary.txt).

set -euo pipefail

device=${1:-00008130-0011305E34D8001C}
bundle=${2:-us.wilddolphin.signal}
out=~/Desktop/SignalLogs/$(date +%Y%m%d-%H%M%S)
mkdir -p $out/crashes-all $out/crashes $out/logs

echo "Copying crash reports…"
xcrun devicectl device copy from --device $device --domain-type systemCrashLogs \
  --source / --destination $out/crashes-all >/dev/null
find $out/crashes-all -name 'Signal*.ips' -exec mv {} $out/crashes/ \;
rm -rf $out/crashes-all

echo "Copying app logs…"
xcrun devicectl device copy from --device $device --domain-type appDataContainer \
  --domain-identifier $bundle --source Library/Caches/Logs --destination $out/logs >/dev/null

python3 - $out <<'EOF' | tee $out/summary.txt
import glob, json, os, re, sys
out = sys.argv[1]

crashes = sorted(glob.glob(f"{out}/crashes/*.ips"), key=os.path.getmtime)
print(f"\n=== {len(crashes)} Signal crash report(s) ===")
for path in crashes[-1:]:
    header, body = open(path).read().split("\n", 1)
    report = json.loads(body)
    print(f"Latest: {os.path.basename(path)}  ({json.loads(header).get('timestamp', '')})")
    print("Exception:", report.get("exception"), report.get("termination", {}).get("indicator", ""))
    images = report["usedImages"]
    thread = next(t for t in report["threads"] if t.get("triggered"))
    print("Crashed thread:", thread.get("queue", thread.get("name", "")))
    for frame in thread["frames"][:18]:
        image = images[frame["imageIndex"]].get("name", "?")
        print(f"  {image:28} {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")

logs = sorted(glob.glob(f"{out}/logs/*.log"), key=os.path.getmtime)
interesting = re.compile(r"Voice commands|AutoSTT|CallAudioService.*(failed|changed)|ERR|owsFail|Assertion|onCallEnded")
print(f"\n=== Recent activity from {len(logs)} log file(s) ===")
lines = [l.rstrip() for path in logs for l in open(path, errors="replace") if interesting.search(l)]
for line in lines[-80:]:
    print(line)
EOF

echo "\nSaved to $out"
open $out
