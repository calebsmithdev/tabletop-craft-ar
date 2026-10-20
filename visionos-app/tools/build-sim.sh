#!/bin/bash
# Builds the app for the visionOS simulator. SIMULATOR (a device name or UDID) picks the destination.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
simulator=${SIMULATOR:-Apple Vision Pro}
if [[ $simulator =~ ^[0-9A-F-]{36}$ ]]; then destination="id=$simulator"; else destination="name=$simulator"; fi
xcodebuild -project TabletopCraft.xcodeproj -scheme TabletopCraft \
  -destination "platform=visionOS Simulator,$destination" \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO "$@" build
