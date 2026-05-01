#!/usr/bin/env bash
# Single-command verification of the C4/D filter behavior.
# Bumps CURRENT_PROJECT_VERSION (so OS sees a new extension), builds via
# xcodebuild, deploys to /Applications, kills old processes, launches,
# runs curl tests, captures filter+activator logs, emits a clear verdict,
# then reverts the version bump so working tree stays clean.
#
# RUN AS: ~/projects/FoqosUp/scripts/c4-verify.sh
# (no sudo — needs user-level Xcode + /Applications access)

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/FoqosMac/FoqosMac.xcodeproj"
EXT_BUNDLE=com.usetessera.mybrick.FoqosMac.FoqosMacFilter
DEPLOYED=/Applications/FoqosMac.app
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
OUT="$(dirname "$0")/c4-verify.out"
[ -f "$OUT" ] && [ ! -w "$OUT" ] && rm -f "$OUT" 2>/dev/null
[ -f "$OUT" ] && [ ! -w "$OUT" ] && sudo rm -f "$OUT"
: > "$OUT"
say() { echo "$@" | tee -a "$OUT"; }
fail_clean() {
  git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj 2>/dev/null
  exit 1
}
trap fail_clean ERR

say "===== 1. Bump version (transient) ====="
cd "$ROOT/FoqosMac"
PRE=$(grep -m1 "CURRENT_PROJECT_VERSION" FoqosMac.xcodeproj/project.pbxproj | grep -oE '[0-9]+;' | tr -d ';')
NEW=$((PRE + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = ${PRE};/CURRENT_PROJECT_VERSION = ${NEW};/g" FoqosMac.xcodeproj/project.pbxproj
say "$PRE → $NEW"

say ""
say "===== 2. Clean any stale /Applications/FoqosMac.app ====="
pkill -9 -x FoqosMac 2>/dev/null && say "killed FoqosMac container" || say "no FoqosMac running"
pkill -9 -f "$EXT_BUNDLE" 2>/dev/null && say "killed FoqosMacFilter" || true
sleep 1
if [ -d "$DEPLOYED" ]; then
  if ! rm -rf "$DEPLOYED" 2>/dev/null; then
    say "rm /Applications/FoqosMac.app failed without sudo, retrying..."
    sudo rm -rf "$DEPLOYED"
  fi
fi
say "/Applications cleared."

say ""
say "===== 3. Build ====="
cd "$ROOT"
BUILD_LOG="$(dirname "$0")/.c4-build.log"
if xcodebuild -project "$PROJ" -scheme FoqosMac -configuration Debug \
     -destination 'platform=macOS' CODE_SIGN_STYLE=Automatic build > "$BUILD_LOG" 2>&1; then
  say "BUILD SUCCEEDED"
else
  say "BUILD FAILED — last 30 lines:"
  tail -30 "$BUILD_LOG" | tee -a "$OUT"
  fail_clean
fi
DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)/Build/Products/Debug/FoqosMac.app"
say "Built: $DERIVED"

say ""
say "===== 4. Verify embedded extension Info.plist ====="
EXT_PLIST="$DERIVED/Contents/Library/SystemExtensions/${EXT_BUNDLE}.systemextension/Contents/Info.plist"
plutil -p "$EXT_PLIST" | grep -E "NEMachServiceName|CFBundleVersion" | tee -a "$OUT"

say ""
say "===== 5. Deploy ====="
ditto "$DERIVED" "$DEPLOYED"
say "Deployed."

say ""
say "===== 6. Launch + wait for activation ====="
LAUNCH_T=$(date +%s)
START_T_STR=$(date -r "$LAUNCH_T" '+%Y-%m-%d %H:%M:%S')
open "$DEPLOYED"
say "Launched. Sleeping 12s..."
sleep 12

say ""
say "===== 7. systemextensionsctl list ====="
systemextensionsctl list 2>&1 | grep -E "(FoqosMac|^enabled)" | head -10 | tee -a "$OUT"

say ""
say "===== 8. CURL tests ====="
say ""
say "----- A. example.com (expect: timeout/handshake fail) -----"
A_RESULT=$(curl -v --max-time 8 https://example.com 2>&1 | tail -20)
echo "$A_RESULT" | tee -a "$OUT"
A_OK="false"
echo "$A_RESULT" | grep -qE "Operation timed out|SSL connect error|Could not resolve|Connection refused|Connection reset|Failed to connect|Empty reply|handshake failure" && A_OK="true"

say ""
say "----- B. google.com (expect: success) -----"
B_RESULT=$(curl -v --max-time 8 https://google.com 2>&1 | tail -10)
echo "$B_RESULT" | tee -a "$OUT"
B_OK="false"
echo "$B_RESULT" | grep -qE "HTTP/[12].* 30[12]|HTTP/[12].* 200" && B_OK="true"

say ""
say "----- C. www.example.com (subdomain — expect: timeout/fail) -----"
C_RESULT=$(curl -v --max-time 8 https://www.example.com 2>&1 | tail -15)
echo "$C_RESULT" | tee -a "$OUT"
C_OK="false"
echo "$C_RESULT" | grep -qE "Operation timed out|SSL connect error|Could not resolve|Connection refused|Connection reset|Failed to connect|Empty reply|handshake failure" && C_OK="true"

sleep 2

say ""
say "===== 9. Filter logs since launch ====="
/usr/bin/log show --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'FilterDataProvider'" \
  --style compact --info --debug --start "$START_T_STR" 2>&1 | tee -a "$OUT"

say ""
say "===== 10. Activator logs since launch ====="
/usr/bin/log show --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'ExtensionActivator'" \
  --style compact --info --debug --start "$START_T_STR" 2>&1 | tee -a "$OUT"

say ""
say "===== VERDICT ====="
SNI_DROPS=$(grep -c "SNI DROP example.com" "$OUT" 2>/dev/null || true)
SNI_NILS=$(grep -c "SNI nil" "$OUT" 2>/dev/null || true)
QUIC_DROPS=$(grep -c "DROP udp/443" "$OUT" 2>/dev/null || true)
say "example.com curl blocked     : $A_OK"
say "google.com   curl OK         : $B_OK"
say "www.example.com  blocked     : $C_OK"
say "SNI DROP example.com lines   : $SNI_DROPS"
say "SNI nil lines                : $SNI_NILS"
say "QUIC blackhole DROP lines    : $QUIC_DROPS"
say ""
if [ "$A_OK" = "true" ] && [ "$B_OK" = "true" ] && [ "$C_OK" = "true" ]; then
  say "✓✓✓ SUCCESS — filter blocks example.com + www.example.com, allows google.com"
else
  say "✗ INCOMPLETE — see logs above"
fi

say ""
say "===== 11. Revert version bump ====="
git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj
say "Working tree clean."

say ""
say "Done. Output: $OUT"
