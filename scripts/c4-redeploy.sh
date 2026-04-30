#!/usr/bin/env bash
# Clean redeploy + diagnose for C4. Run AFTER ⌘B in Xcode.
# This script does NOT uninstall the existing extension (would require SIP off).
# Instead it relies on OSSystemExtensionRequest's .replace action to swap binaries.

set -u
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/FoqosMac-fsmeeficwynbmkfbraofqxxanvav/Build/Products/Debug/FoqosMac.app"
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)/FoqosMac"
EXT_BUNDLE=com.usetessera.mybrick.FoqosMac.FoqosMacFilter
OUT="$(dirname "$0")/c4-redeploy.out"
# Fix root-owned output from prior sudo runs
[ -f "$OUT" ] && [ ! -w "$OUT" ] && rm -f "$OUT" 2>/dev/null
[ -f "$OUT" ] && [ ! -w "$OUT" ] && sudo rm -f "$OUT"
: > "$OUT"
say() { echo "$@" | tee -a "$OUT"; }

say "===== 1. Verify build freshness ====="
if [ ! -d "$DERIVED" ]; then
  say "ERROR: $DERIVED does not exist. Run ⌘B in Xcode."
  exit 1
fi
DERIVED_MTIME=$(stat -f %m "$DERIVED/Contents/MacOS/FoqosMac" 2>/dev/null || echo 0)
SOURCE_MTIME=$(find "$SOURCE_DIR" -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' | xargs stat -f %m | sort -n | tail -1)
say "Build:  $(date -r $DERIVED_MTIME 2>/dev/null)"
say "Source: $(date -r $SOURCE_MTIME 2>/dev/null)"
if [ "$DERIVED_MTIME" -lt "$SOURCE_MTIME" ]; then
  say ""
  say "ERROR: Build is STALE. Source modified after last build."
  say "  → Open Xcode, ⌘⇧K (Clean Build Folder), ⌘B (Build), rerun this script."
  exit 1
fi
say "Build is fresh ✓"

say ""
say "===== 2. Kill all FoqosMac processes ====="
pkill -9 -x FoqosMac 2>/dev/null && say "Killed FoqosMac container" || say "No FoqosMac container process"
pkill -9 -f "$EXT_BUNDLE" 2>/dev/null && say "Killed FoqosMacFilter ext" || say "No FoqosMacFilter process"
sleep 1

say ""
say "===== 3. Replace /Applications/FoqosMac.app ====="
rm -rf /Applications/FoqosMac.app
ditto "$DERIVED" /Applications/FoqosMac.app
say "Copied. Verifying NEMachServiceName in deployed bundle:"
plutil -p /Applications/FoqosMac.app/Contents/Library/SystemExtensions/${EXT_BUNDLE}.systemextension/Contents/Info.plist | grep NEMachServiceName | tee -a "$OUT"

say ""
say "===== 4. Launch /Applications/FoqosMac.app ====="
open /Applications/FoqosMac.app
say "Launched. Waiting 10s for activation request to complete..."
sleep 10

say ""
say "===== 5. systemextensionsctl list ====="
systemextensionsctl list 2>&1 | grep -E "FoqosMac" | tee -a "$OUT"

say ""
say "===== 6. Trigger Safari load ====="
osascript -e 'tell application "Safari" to activate' >/dev/null 2>&1 || true
osascript -e 'tell application "Safari"
  if (count of windows) = 0 then
    make new document
  end if
  set URL of current tab of front window to "https://example.com"
end tell' >/dev/null 2>&1
sleep 3
say "Safari triggered + 3s wait done"
say ""
say "Now also testing curl:"
curl -m 5 -sS -o /dev/null -w "curl example.com: HTTP %{http_code} in %{time_total}s\n" https://example.com 2>&1 | tee -a "$OUT"

say ""
say "===== 7. Container + Extension logs (last 60s, INCL info+debug) ====="
/usr/bin/log show --predicate 'subsystem == "com.usetessera.mybrick"' --style compact --info --debug --last 60s 2>&1 | tee -a "$OUT"

say ""
say "===== 8. Process list ====="
ps -ef | grep -E "FoqosMac|$EXT_BUNDLE" | grep -v grep | tee -a "$OUT"

say ""
say "Done. Output: $OUT"
