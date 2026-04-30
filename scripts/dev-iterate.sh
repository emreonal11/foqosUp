#!/usr/bin/env bash
# One-shot dev iteration. Bumps build number, builds via xcodebuild,
# deploys to /Applications, launches, and tails extension logs.
#
# When the filter target's Swift code changes, the OS only triggers a
# replace if CURRENT_PROJECT_VERSION is different. agvtool bumps it.
# Container-only changes don't strictly need the bump but it's cheap.
#
# This script avoids polluting git: it bumps CURRENT_PROJECT_VERSION,
# builds, then resets the pbxproj so you don't commit the bump.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/FoqosMac/FoqosMac.xcodeproj"
EXT_BUNDLE=com.usetessera.mybrick.FoqosMac.FoqosMacFilter
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)"
DEPLOYED=/Applications/FoqosMac.app

echo "===== 1. Bump CURRENT_PROJECT_VERSION (pbxproj only, will revert) ====="
cd "$ROOT/FoqosMac"
PRE_VERSION=$(grep -m1 "CURRENT_PROJECT_VERSION" FoqosMac.xcodeproj/project.pbxproj | grep -oE '[0-9]+;' | tr -d ';')
NEW_VERSION=$((PRE_VERSION + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = ${PRE_VERSION};/CURRENT_PROJECT_VERSION = ${NEW_VERSION};/g" FoqosMac.xcodeproj/project.pbxproj
echo "Version: $PRE_VERSION → $NEW_VERSION"

echo ""
echo "===== 2. Build via xcodebuild ====="
cd "$ROOT"
# Use Xcode's default DerivedData so subsequent ⌘R also picks it up.
xcodebuild -project "$PROJ" -scheme FoqosMac -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Automatic \
  build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" | tail -20

DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)/Build/Products/Debug/FoqosMac.app"
if [ ! -d "$DERIVED" ]; then
  echo "ERROR: no .app produced at $DERIVED"
  exit 1
fi
echo "Build OK: $DERIVED"

echo ""
echo "===== 3. Revert pbxproj (keep working tree clean) ====="
git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj
echo "pbxproj reverted to committed state"

echo ""
echo "===== 4. Kill running processes + redeploy ====="
pkill -9 -x FoqosMac 2>/dev/null && echo "Killed FoqosMac" || true
pkill -9 -f "$EXT_BUNDLE" 2>/dev/null && echo "Killed FoqosMacFilter" || true
sleep 1
rm -rf "$DEPLOYED"
ditto "$DERIVED" "$DEPLOYED"
echo "Deployed: $DEPLOYED"

echo ""
echo "===== 5. Launch ====="
open "$DEPLOYED"
echo "Launched. Activation request will fire in ~1-2s."

echo ""
echo "===== 6. Streaming logs (⌃C to exit) ====="
echo "Watch for: 'Replacing existing extension' → 'startFilter' → 'flow ...' lines"
echo "----"
exec /usr/bin/log stream --predicate 'subsystem == "com.usetessera.mybrick"' --style compact --info --debug
