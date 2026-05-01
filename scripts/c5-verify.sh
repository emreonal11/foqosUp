#!/usr/bin/env bash
# End-to-end C5 verification:
#   1. Bump version, build, deploy, launch
#   2. With empty App Group → curl example.com should succeed (no blocklist)
#   3. Inject {isBlocked: true, domains: [example.com]} → curl should fail
#   4. Inject {isBlocked: true, isBreakActive: true, ...} → curl should succeed (break suspends)
#   5. Inject {isBlocked: false, ...} → curl should succeed (not blocking)
#   6. Reset App Group, revert pbxproj
#
# Independent of iPhone state. Validates only the container ↔ App Group ↔
# Darwin notification ↔ filter pipeline.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/FoqosMac/FoqosMac.xcodeproj"
EXT_BUNDLE=com.usetessera.mybrick.FoqosMac.FoqosMacFilter
DEPLOYED=/Applications/FoqosMac.app
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
SUITE=group.com.usetessera.mybrick
KEY=com.usetessera.mybrick.blocklist.v1
DARWIN_NAME=com.usetessera.mybrick.state.changed
OUT="$(dirname "$0")/c5-verify.out"
[ -f "$OUT" ] && [ ! -w "$OUT" ] && rm -f "$OUT" 2>/dev/null
[ -f "$OUT" ] && [ ! -w "$OUT" ] && sudo rm -f "$OUT"
: > "$OUT"
say() { echo "$@" | tee -a "$OUT"; }
fail_clean() {
  git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj 2>/dev/null
  exit 1
}
trap fail_clean ERR

inject_snapshot() {
  local json="$1"
  local hex
  hex=$(echo -n "$json" | xxd -p | tr -d '\n ')
  defaults write "$SUITE" "$KEY" -data "$hex"
  swift -e "import CoreFoundation; import Foundation; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(\"$DARWIN_NAME\" as CFString), nil, nil, true)"
}

reset_snapshot() {
  defaults delete "$SUITE" "$KEY" 2>/dev/null || true
  swift -e "import CoreFoundation; import Foundation; CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(\"$DARWIN_NAME\" as CFString), nil, nil, true)"
}

curl_ok() {
  # Returns 0 if curl succeeded with HTTP 2xx/3xx, 1 otherwise.
  local url="$1"
  local code
  code=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^[23] ]]; then return 0; else return 1; fi
}

curl_blocked() {
  # Returns 0 if curl FAILED to connect/handshake (which is what we want when
  # the filter is blocking). Returns 1 if it succeeded.
  local url="$1"
  if curl_ok "$url"; then return 1; else return 0; fi
}

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    say "  ✓ $name (got $actual)"
    PASS=$((PASS + 1))
  else
    say "  ✗ $name (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

say "===== 1. Bump version + build + deploy ====="
cd "$ROOT/FoqosMac"
PRE=$(grep -m1 "CURRENT_PROJECT_VERSION" FoqosMac.xcodeproj/project.pbxproj | grep -oE '[0-9]+;' | tr -d ';')
NEW=$((PRE + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = ${PRE};/CURRENT_PROJECT_VERSION = ${NEW};/g" FoqosMac.xcodeproj/project.pbxproj
say "version: $PRE → $NEW"

pkill -9 -x FoqosMac 2>/dev/null || true
pkill -9 -f "$EXT_BUNDLE" 2>/dev/null || true
sleep 1
[ -d "$DEPLOYED" ] && (rm -rf "$DEPLOYED" 2>/dev/null || sudo rm -rf "$DEPLOYED")

cd "$ROOT"
BUILD_LOG="$(dirname "$0")/.c5-build.log"
if xcodebuild -project "$PROJ" -scheme FoqosMac -configuration Debug \
     -destination 'platform=macOS' CODE_SIGN_STYLE=Automatic build > "$BUILD_LOG" 2>&1; then
  say "BUILD SUCCEEDED"
else
  say "BUILD FAILED — last 30 lines:"
  tail -30 "$BUILD_LOG" | tee -a "$OUT"
  fail_clean
fi
DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)/Build/Products/Debug/FoqosMac.app"
ditto "$DERIVED" "$DEPLOYED"
say "deployed."

LAUNCH_T=$(date +%s)
START_T_STR=$(date -r "$LAUNCH_T" '+%Y-%m-%d %H:%M:%S')
open "$DEPLOYED"
say "launched. Sleeping 14s for activation..."
sleep 14

systemextensionsctl list 2>&1 | grep -E "FoqosMac" | head -3 | tee -a "$OUT"

say ""
say "===== 2. Test 1: empty App Group → example.com should succeed ====="
reset_snapshot
sleep 2
T1=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://example.com 2>/dev/null || echo "000")
say "  curl example.com → $T1"
if [[ "$T1" =~ ^[23] ]]; then check "T1: example.com works (no blocklist)" "ok" "ok"; else check "T1: example.com works (no blocklist)" "ok" "blocked-or-failed:$T1"; fi

say ""
say "===== 3. Test 2: inject {isBlocked: true, domains: [example.com]} ====="
inject_snapshot '{"isBlocked":true,"isBreakActive":false,"isPauseActive":false,"domains":["example.com"],"lastUpdated":1}'
sleep 2
T2=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://example.com 2>/dev/null || echo "blocked")
say "  curl example.com → $T2"
if [[ "$T2" =~ ^[23] ]]; then check "T2: example.com blocked" "blocked" "ok:$T2"; else check "T2: example.com blocked" "blocked" "blocked"; fi

# google.com should still work
T2g=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://google.com 2>/dev/null || echo "000")
say "  curl google.com  → $T2g"
if [[ "$T2g" =~ ^[23] ]]; then check "T2: google.com works (not in blocklist)" "ok" "ok"; else check "T2: google.com works" "ok" "failed:$T2g"; fi

say ""
say "===== 4. Test 3: isBreakActive=true suspends blocking ====="
inject_snapshot '{"isBlocked":true,"isBreakActive":true,"isPauseActive":false,"domains":["example.com"],"lastUpdated":2}'
sleep 2
T3=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://example.com 2>/dev/null || echo "000")
say "  curl example.com (break active) → $T3"
if [[ "$T3" =~ ^[23] ]]; then check "T3: example.com works during break" "ok" "ok"; else check "T3: example.com works during break" "ok" "blocked:$T3"; fi

say ""
say "===== 5. Test 4: subdomain match — block .example.com ====="
inject_snapshot '{"isBlocked":true,"isBreakActive":false,"isPauseActive":false,"domains":["example.com"],"lastUpdated":3}'
sleep 2
T4=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://www.example.com 2>/dev/null || echo "blocked")
say "  curl www.example.com (subdomain) → $T4"
if [[ "$T4" =~ ^[23] ]]; then check "T4: www.example.com blocked (suffix match)" "blocked" "ok:$T4"; else check "T4: www.example.com blocked (suffix match)" "blocked" "blocked"; fi

say ""
say "===== 6. Test 5: isBlocked=false → all allowed ====="
inject_snapshot '{"isBlocked":false,"isBreakActive":false,"isPauseActive":false,"domains":["example.com"],"lastUpdated":4}'
sleep 2
T5=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://example.com 2>/dev/null || echo "000")
say "  curl example.com (isBlocked=false) → $T5"
if [[ "$T5" =~ ^[23] ]]; then check "T5: example.com works when isBlocked=false" "ok" "ok"; else check "T5: example.com works when isBlocked=false" "ok" "blocked:$T5"; fi

sleep 2

say ""
say "===== 7. Filter logs ====="
/usr/bin/log show --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'FilterDataProvider'" \
  --style compact --info --debug --start "$START_T_STR" 2>&1 | grep -E "(Reloaded|SNI|Darwin)" | tail -40 | tee -a "$OUT"

say ""
say "===== 8. BlocklistState reload logs ====="
/usr/bin/log show --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'BlocklistState'" \
  --style compact --info --debug --start "$START_T_STR" 2>&1 | tail -20 | tee -a "$OUT"

say ""
say "===== 9. Reset ====="
reset_snapshot

say ""
say "===== VERDICT ====="
say "Passed: $PASS"
say "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  say "✓✓✓ C5 PIPELINE VERIFIED — all 6 assertions passed"
else
  say "✗ Some assertions failed — see above"
fi

say ""
say "===== 10. Revert pbxproj ====="
git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj
say "Working tree clean."

say ""
say "Done. Output: $OUT"
