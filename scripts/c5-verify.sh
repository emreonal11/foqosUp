#!/usr/bin/env bash
# C5 verification (post-XPC pivot):
#   1. Bump version, build, deploy, launch.
#   2. XPC handshake smoke test — independent of iCloud state. Tail logs for
#      a few seconds and assert the IPCService listener started, IPCClient
#      connected, and at least one snapshot was received.
#   3. Real-iPhone end-to-end test (optional gate). Requires the user's
#      iPhone to be in a known state. The script prints the iCloud-derived
#      blocklist as observed by the container, then runs curl against
#      domain(s) the user provides and asserts block-vs-allow.
#
# Synthetic shell injection (the previous "defaults write group.X ..."
# pattern) is removed: the filter sysext runs as root and its App Group
# UserDefaults storage is under /var/root, disjoint from any path a user-
# level shell can write to. See CLAUDE.md §11 / scripts/c5-lsof-check.out.
#
# Output: scripts/c5-verify.out (verbatim logs + verdict).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/FoqosMac/FoqosMac.xcodeproj"
EXT_BUNDLE=com.usetessera.mybrick.FoqosMac.FoqosMacFilter
DEPLOYED=/Applications/FoqosMac.app
DERIVED_BASE="$HOME/Library/Developer/Xcode/DerivedData"
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

PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    say "  ✓ $name"
    PASS=$((PASS + 1))
  else
    say "  ✗ $name (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# --- 1. Build + deploy + launch -----------------------------------------------
say "===== 1. Bump version + build + deploy ====="
cd "$ROOT/FoqosMac"
PRE=$(grep -m1 "CURRENT_PROJECT_VERSION" FoqosMac.xcodeproj/project.pbxproj | grep -oE '[0-9]+;' | tr -d ';')
NEW=$(date +%s)
sed -i '' "s/CURRENT_PROJECT_VERSION = ${PRE};/CURRENT_PROJECT_VERSION = ${NEW};/g" FoqosMac.xcodeproj/project.pbxproj
say "version: $PRE → $NEW (epoch — guaranteed unique per run)"

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
  say "BUILD FAILED — last 40 lines:"
  tail -40 "$BUILD_LOG" | tee -a "$OUT"
  fail_clean
fi
DERIVED="$(ls -td "$DERIVED_BASE"/FoqosMac-* 2>/dev/null | head -1)/Build/Products/Debug/FoqosMac.app"
ditto "$DERIVED" "$DEPLOYED"
say "deployed."

LAUNCH_T=$(date +%s)
START_T_STR=$(date -r "$LAUNCH_T" '+%Y-%m-%d %H:%M:%S')
open "$DEPLOYED"
say "launched. Sleeping 15s for activation + first XPC handshake (incl. retry backoff)..."
sleep 15

systemextensionsctl list 2>&1 | grep -E "FoqosMac" | head -10 | tee -a "$OUT"
say ""

# --- 2. XPC handshake smoke test ----------------------------------------------
say "===== 2. XPC handshake smoke test ====="
say "Tailing 4s of logs for IPCService + IPCClient activity..."

COMBINED_LOGS="$(/usr/bin/log show \
    --predicate "subsystem == 'com.usetessera.mybrick' AND (category == 'IPCService' OR category == 'IPCClient')" \
    --style compact --info --debug --start "$START_T_STR" 2>&1)"

echo "$COMBINED_LOGS" | tail -40 | tee -a "$OUT"
say ""

if echo "$COMBINED_LOGS" | grep -q "XPC listener started"; then
  check "Filter listener started" "ok" "ok"
else
  check "Filter listener started" "ok" "missing"
fi

if echo "$COMBINED_LOGS" | grep -q "XPC client connected"; then
  check "Filter accepted client connection" "ok" "ok"
else
  check "Filter accepted client connection" "ok" "missing"
fi

if echo "$COMBINED_LOGS" | grep -q "Snapshot received:"; then
  check "Filter received at least one snapshot" "ok" "ok"
else
  check "Filter received at least one snapshot" "ok" "missing"
fi

if echo "$COMBINED_LOGS" | grep -qE "Published \(attempt [0-9]+\): blocked="; then
  check "Container published at least one snapshot" "ok" "ok"
else
  check "Container published at least one snapshot" "ok" "missing"
fi

# --- 3. BlocklistState reflects iCloud state ----------------------------------
say ""
say "===== 3. BlocklistState reflects iCloud-derived state ====="
BLOCKLIST_LOGS="$(/usr/bin/log show \
    --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'BlocklistState'" \
    --style compact --info --debug --start "$START_T_STR" 2>&1)"
echo "$BLOCKLIST_LOGS" | tail -20 | tee -a "$OUT"
say ""

LATEST_UPDATE_LINE=$(echo "$BLOCKLIST_LOGS" | grep "Updated:" | tail -1)
if [ -n "$LATEST_UPDATE_LINE" ]; then
  check "BlocklistState received update from XPC" "ok" "ok"
  say "  latest: $(echo "$LATEST_UPDATE_LINE" | sed 's/.*Updated: //')"
else
  check "BlocklistState received update from XPC" "ok" "missing"
fi

# --- 4. Optional real-iPhone block test --------------------------------------
say ""
say "===== 4. Real-iPhone block test (optional) ====="
say "If your iPhone is currently bricked with a known domain in the active"
say "profile, set TEST_BLOCKED_DOMAIN env var to that domain to run this"
say "section. Otherwise this section is informational only."
say ""

if [ -n "${TEST_BLOCKED_DOMAIN:-}" ]; then
  say "TEST_BLOCKED_DOMAIN=$TEST_BLOCKED_DOMAIN"
  CODE=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" "https://$TEST_BLOCKED_DOMAIN" 2>/dev/null || echo "blocked")
  say "  curl https://$TEST_BLOCKED_DOMAIN → $CODE"
  if [[ "$CODE" =~ ^[23] ]]; then
    check "Blocked domain unreachable" "blocked" "got HTTP $CODE"
  else
    check "Blocked domain unreachable" "blocked" "blocked"
  fi
else
  say "  (skipped — set TEST_BLOCKED_DOMAIN to enable)"
fi

# Always sanity-check that an unblocked domain works (filter isn't a blackhole).
SANE=$(curl -m 6 -sS -o /dev/null -w "%{http_code}" https://www.apple.com 2>/dev/null || echo "blackhole")
say "  curl https://www.apple.com → $SANE"
if [[ "$SANE" =~ ^[23] ]]; then
  check "Unblocked domain reachable (filter not blackholing)" "ok" "ok"
else
  check "Unblocked domain reachable (filter not blackholing)" "ok" "$SANE"
fi

# --- 5. FilterDataProvider activity (diagnostic) ------------------------------
say ""
say "===== 5. FilterDataProvider activity ====="
/usr/bin/log show \
    --predicate "subsystem == 'com.usetessera.mybrick' AND category == 'FilterDataProvider'" \
    --style compact --info --debug --start "$START_T_STR" 2>&1 \
  | grep -E "(startFilter|Filter settings|SNI DROP|SNI allow|flow DROP)" \
  | tail -30 | tee -a "$OUT"

# --- 6. Verdict ---------------------------------------------------------------
say ""
say "===== VERDICT ====="
say "Passed: $PASS"
say "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  say "✓✓✓ C5 XPC pipeline VERIFIED"
else
  say "✗ Some assertions failed — see logs above"
fi

# --- 7. Revert pbxproj --------------------------------------------------------
say ""
say "===== Cleanup: revert pbxproj version bump ====="
git -C "$ROOT" checkout FoqosMac/FoqosMac.xcodeproj/project.pbxproj
say "Working tree clean."

say ""
say "Done. Output: $OUT"
