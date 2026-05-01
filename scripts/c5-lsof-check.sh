#!/usr/bin/env bash
# Ground-truth the C5 BLOCKER hypothesis: is the filter sysext (root) really
# reading from a different App Group container path than the user-level
# container app? Captures verbatim evidence for the commit message.
set -u
OUT="$(dirname "$0")/c5-lsof-check.out"
: > "$OUT"
say() { echo "$@" | tee -a "$OUT"; }

say "===== c5-lsof-check ($(date)) ====="
say ""

# Make sure FoqosMac is running so the filter is loaded.
if ! pgrep -x FoqosMac >/dev/null; then
  say "FoqosMac not running — launching /Applications/FoqosMac.app"
  open /Applications/FoqosMac.app 2>/dev/null || open -a FoqosMac
  sleep 4
fi

FILTER_PID=$(pgrep -f "com.usetessera.mybrick.FoqosMac.FoqosMacFilter" | head -1)
CONTAINER_PID=$(pgrep -x FoqosMac | head -1)

say "Filter PID:    ${FILTER_PID:-<not running>}"
say "Container PID: ${CONTAINER_PID:-<not running>}"
say ""

if [ -z "$FILTER_PID" ] || [ -z "$CONTAINER_PID" ]; then
  say "Need both processes running. Aborting."
  exit 1
fi

say "===== ps -p ... -o uid,user,command (filter + container) ====="
ps -p "$FILTER_PID" -o uid,user,command 2>&1 | tee -a "$OUT"
ps -p "$CONTAINER_PID" -o uid,user,command 2>&1 | tee -a "$OUT"
say ""

say "===== sudo lsof on filter, grep group.com.usetessera ====="
sudo lsof -p "$FILTER_PID" 2>/dev/null | grep -i "group.com.usetessera\|usetessera.mybrick\|/var/root\|preferences" | tee -a "$OUT" || say "  (no matches)"
say ""

say "===== lsof on container, grep group.com.usetessera ====="
lsof -p "$CONTAINER_PID" 2>/dev/null | grep -i "group.com.usetessera\|usetessera.mybrick" | tee -a "$OUT" || say "  (no matches)"
say ""

say "===== Files actually present on disk ====="
say "/var/root/Library/Group Containers/:"
sudo ls -la "/var/root/Library/Group Containers/" 2>&1 | grep -i usetessera | tee -a "$OUT" || say "  (no usetessera entries)"
say ""
say "/var/root/Library/Preferences/group.com.usetessera.mybrick.plist:"
sudo ls -la "/var/root/Library/Preferences/group.com.usetessera.mybrick.plist" 2>&1 | tee -a "$OUT" || true
say ""
say "/var/root/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/:"
sudo ls -la "/var/root/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/" 2>&1 | tee -a "$OUT" || true
say ""
say "User side (~/Library/...):"
ls -la "$HOME/Library/Preferences/group.com.usetessera.mybrick.plist" 2>&1 | tee -a "$OUT" || true
ls -la "$HOME/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/group.com.usetessera.mybrick.plist" 2>&1 | tee -a "$OUT" || true

say ""
say "===== root-side defaults read attempt ====="
sudo defaults read group.com.usetessera.mybrick com.usetessera.mybrick.blocklist.v1 2>&1 | head -5 | tee -a "$OUT" || true
say ""

say ""
say "Done. Output written to $OUT — paste this back to Claude."
