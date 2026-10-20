#!/bin/bash
# Builds, installs and launches on the booted visionOS simulator, opening the table at once (DEBUG builds).
set -euo pipefail
cd "$(dirname "$0")/.."
./tools/build-sim.sh
xcrun simctl install booted DerivedData/Build/Products/Debug-xrsimulator/TabletopCraft.app
xcrun simctl launch booted com.tabletopcraft.ar.visionos -openTableOnLaunch "$@"
