#!/usr/bin/env bash
# Deploy + test only. No xcodebuild. Use this after ⌘B in Xcode.
# Verifies that the FoqosMacFilter system extension drops example.com
# while letting google.com through.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_BUNDLE=com.usetessera.mybrick.FoqosMac.FoqosMacFilter
DEPLOYED=/Applications/FoqosMac.app
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)/Build/Products/Debug/FoqosMac.app"
OUT="$(dirname "$0")/c4-test.out"
[ -f "$OUT" ] && [ ! -w "$OUT" ] && rm -f "$OUT" 2>/dev/null
[ -f "$OUT" ] && [ ! -w "$OUT" ] && sudo rm -f "$OUT"
: > "$OUT"
say() { echo "$@" | tee -a "$OUT"; }

if [ ! -d "$DERIVED" ]; then
  say "ERROR: no FoqosMac.app in DerivedData. Run ⌘B in Xcode first."
  exit 1
fi

say "===== 1. Build freshness ====="
SOURCE_MTIME=$(find "$ROOT/FoqosMac" \( -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' \) -exec stat -f %m {} \; | sort -n | tail -1)
DERIVED_MTIME=$(stat -f %m "$DERIVED/Contents/MacOS/FoqosMac" 2>/dev/null || echo 0)
say "Source: $(date -r $SOURCE_MTIME 2>/dev/null)"
say "Build:  $(date -r $DERIVED_MTIME 2>/dev/null)"
if [ "$DERIVED_MTIME" -lt "$SOURCE_MTIME" ]; then
  say "ERROR: Build is STALE. ⌘⇧K + ⌘B in Xcode, then re-run this script."
  exit 1
fi
say "Fresh ✓"

say ""
say "===== 2. Verify embedded extension Info.plist ====="
EXT_PLIST="$DERIVED/Contents/Library/SystemExtensions/${EXT_BUNDLE}.systemextension/Contents/Info.plist"
plutil -p "$EXT_PLIST" | grep -E "NEMachServiceName|CFBundleVersion" | tee -a "$OUT"
EMBEDDED_VERSION=$(plutil -extract CFBundleVersion raw "$EXT_PLIST")
say "Embedded extension CFBundleVersion: $EMBEDDED_VERSION"

say ""
say "===== 3. Kill running processes ====="
pkill -9 -x FoqosMac 2>/dev/null && say "killed FoqosMac container" || say "no FoqosMac running"
pkill -9 -f "$EXT_BUNDLE" 2>/dev/null && say "killed FoqosMacFilter" || true
sleep 1

say ""
say "===== 4. Deploy ====="
rm -rf "$DEPLOYED"
ditto "$DERIVED" "$DEPLOYED"
DEPLOYED_VERSION=$(plutil -extract CFBundleVersion raw "$DEPLOYED/Contents/Library/SystemExtensions/${EXT_BUNDLE}.systemextension/Contents/Info.plist")
say "Deployed extension CFBundleVersion: $DEPLOYED_VERSION"
if [ "$DEPLOYED_VERSION" = "1" ]; then
  say "WARNING: extension version is 1 — same as previously-staged extension."
  say "OS may skip actionForReplacingExtension and keep running OLD code."
  say "Bump CURRENT_PROJECT_VERSION in pbxproj before ⌘B if you need to force replace."
fi

say ""
say "===== 5. Launch + wait for activation ====="
LAUNCH_T=$(date +%s)
START_T_STR=$(date -r "$LAUNCH_T" '+%Y-%m-%d %H:%M:%S')
open "$DEPLOYED"
say "Launched at $LAUNCH_T. Sleeping 12s..."
sleep 12

say ""
say "===== 6. systemextensionsctl list (FoqosMac) ====="
systemextensionsctl list 2>&1 | grep -E "(FoqosMac|^enabled)" | head -10 | tee -a "$OUT"

say ""
say "===== 7. CURL tests ====="
say ""
say "----- A. example.com (expect: timeout / handshake fail) -----"
A_RESULT=$(curl -v --max-time 8 https://example.com 2>&1 | tail -25)
echo "$A_RESULT" | tee -a "$OUT"
A_OK="false"
if echo "$A_RESULT" | grep -qE "Operation timed out|SSL connect error|Could not resolve|Connection refused|Connection reset|Failed to connect"; then
  A_OK="true"
fi

say ""
say "----- B. google.com (expect: success) -----"
B_RESULT=$(curl -v --max-time 8 https://google.com 2>&1 | tail -10)
echo "$B_RESULT" | tee -a "$OUT"
B_OK="false"
if echo "$B_RESULT" | grep -qE "HTTP/[12].* 30[12]|HTTP/[12].* 200"; then
  B_OK="true"
fi

say ""
say "----- C. www.example.com (subdomain — expect: timeout/fail) -----"
C_RESULT=$(curl -v --max-time 8 https://www.example.com 2>&1 | tail -15)
echo "$C_RESULT" | tee -a "$OUT"
C_OK="false"
if echo "$C_RESULT" | grep -qE "Operation timed out|SSL connect error|Could not resolve|Connection refused|Connection reset|Failed to connect"; then
  C_OK="true"
fi

sleep 2

say ""
say "===== 8. Filter logs since launch ====="
/usr/bin/log show --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'FilterDataProvider'" \
  --style compact --info --debug --start "$START_T_STR" 2>&1 | tee -a "$OUT"

say ""
say "===== 9. Activator logs since launch ====="
/usr/bin/log show --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'ExtensionActivator'" \
  --style compact --info --debug --start "$START_T_STR" 2>&1 | tee -a "$OUT"

say ""
say "===== VERDICT ====="
SNI_DROPS=$(grep -c "SNI DROP example.com" "$OUT" 2>/dev/null | head -1 || echo 0)
SNI_NILS=$(grep -c "SNI nil" "$OUT" 2>/dev/null | head -1 || echo 0)
QUIC_DROPS=$(grep -c "DROP udp/443" "$OUT" 2>/dev/null | head -1 || echo 0)
say "example.com curl blocked: $A_OK"
say "google.com   curl OK    : $B_OK"
say "www.example.com blocked : $C_OK"
say "SNI DROP example.com lines: $SNI_DROPS"
say "SNI nil lines             : $SNI_NILS"
say "QUIC blackhole DROP lines : $QUIC_DROPS"

if [ "$A_OK" = "true" ] && [ "$B_OK" = "true" ]; then
  say ""
  say "✓✓✓ SUCCESS — filter blocks example.com, allows google.com"
else
  say ""
  say "✗ FAILURE — filter is not behaving as expected. See logs above."
fi

say ""
say "Done. Output: $OUT"
