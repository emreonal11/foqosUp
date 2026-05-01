#!/usr/bin/env bash
# Self-deploy FoqosMac to /Applications (Debug build).
#
# Use this for fast iteration without the full c5-verify.sh assertion
# suite. Bumps CURRENT_PROJECT_VERSION to `date +%s` so sysextd takes
# the .replace path (otherwise it may skip the swap if (bundleID,
# version) already matches). Reverts the pbxproj at end so the working
# tree stays clean.
#
# Distribution (Developer ID + notarize) is documented in CLAUDE.md
# §18 — that's a separate, manual flow.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/FoqosMac/FoqosMac.xcodeproj"
DEPLOYED=/Applications/FoqosMac.app
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
BUILD_LOG="$(dirname "$0")/.deploy-mac.log"

cd "$ROOT/FoqosMac"
PRE=$(grep -m1 "CURRENT_PROJECT_VERSION" FoqosMac.xcodeproj/project.pbxproj | grep -oE '[0-9]+;' | tr -d ';')
NEW=$(date +%s)
sed -i '' "s/CURRENT_PROJECT_VERSION = ${PRE};/CURRENT_PROJECT_VERSION = ${NEW};/g" FoqosMac.xcodeproj/project.pbxproj
echo "version: $PRE → $NEW"

# Always restore the pbxproj on exit, even on build failure / interrupt.
trap 'git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj 2>/dev/null || true' EXIT

# Stop running processes so the .app can be replaced.
pkill -9 -x FoqosMac 2>/dev/null || true
pkill -9 -f "com.usetessera.mybrick.FoqosMac.FoqosMacFilter" 2>/dev/null || true
sleep 1
[ -d "$DEPLOYED" ] && (rm -rf "$DEPLOYED" 2>/dev/null || sudo rm -rf "$DEPLOYED")

cd "$ROOT"
echo "Building..."
if ! xcodebuild -project "$PROJ" -scheme FoqosMac -configuration Debug \
     -destination 'platform=macOS' CODE_SIGN_STYLE=Automatic build \
     > "$BUILD_LOG" 2>&1; then
  echo "BUILD FAILED — last 30 lines:"
  tail -30 "$BUILD_LOG"
  exit 1
fi
echo "BUILD SUCCEEDED"

DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)/Build/Products/Debug/FoqosMac.app"
[ -d "$DERIVED" ] || { echo "Could not find built .app at $DERIVED"; exit 1; }
ditto "$DERIVED" "$DEPLOYED"
echo "Deployed to $DEPLOYED"

open "$DEPLOYED"
echo "Launched. Menu bar icon should appear within a second or two."
echo ""
echo "Tail filter logs in another terminal with:"
echo "  log stream --predicate \"subsystem == 'com.usetessera.mybrick'\" --info --debug --style compact"
