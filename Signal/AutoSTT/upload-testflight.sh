#!/bin/zsh
# Upload the App Store Release archive to TestFlight.
# Requires Xcode → Settings → Accounts signed in with App Store Connect
# access for team PPZTNTHDFC.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ARCHIVE="$ROOT/build/SignalPlusAI.xcarchive"
if [[ ! -d "$ARCHIVE" ]]; then
  echo "Archiving Signal+AI (App Store Release)…"
  xcodebuild -workspace Signal.xcworkspace -scheme Signal \
    -configuration "App Store Release" -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates -derivedDataPath build/TFArchiveDD \
    archive -archivePath "$ARCHIVE"
fi
echo "Exporting and uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist fastlane/ExportOptions-TestFlight.plist \
  -exportPath build/TestFlight -allowProvisioningUpdates
echo "Upload submitted. Processing in App Store Connect can take 5–15 minutes."
echo "Then: App Store Connect → Signal+AI → TestFlight → Internal Testing."
