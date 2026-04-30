#!/usr/bin/env bash
# C4 diagnostic — captures everything needed to figure out why example.com isn't being blocked.
# Output written to scripts/c4-diagnose.out — paste that back.

set -u
OUT="$(dirname "$0")/c4-diagnose.out"
: > "$OUT"

log_section() { echo -e "\n========== $1 ==========\n" >> "$OUT"; }

log_section "1. systemextensionsctl list"
systemextensionsctl list >> "$OUT" 2>&1

log_section "2. NEFilterManager preferences (defaults read)"
defaults read /Library/Preferences/com.apple.networkextension.plist 2>/dev/null >> "$OUT" || \
  echo "(no /Library/Preferences/com.apple.networkextension.plist or read failed)" >> "$OUT"

log_section "3. FoqosMac container logs (last 5 min)"
log show --predicate 'subsystem == "com.usetessera.mybrick"' --style compact --last 5m >> "$OUT" 2>&1

log_section "4. sysextd logs filtered to FoqosMac (last 5 min)"
sudo log show --predicate '(subsystem == "com.apple.sysextd" OR process == "sysextd") AND eventMessage CONTAINS "FoqosMac"' --style compact --last 5m >> "$OUT" 2>&1

log_section "5. neagent logs (the process that runs the filter) (last 5 min)"
sudo log show --predicate 'process == "neagent" OR process == "nesessionmanager"' --style compact --last 5m 2>&1 | tail -200 >> "$OUT"

log_section "6. Trigger a test flow via Safari + curl"
echo "Loading example.com via Safari (NSURLSession path) in 2 seconds..." >> "$OUT"
sleep 1
osascript -e 'tell application "Safari" to activate' >/dev/null 2>&1 || true
osascript -e 'tell application "Safari"
  if (count of windows) = 0 then
    make new document
  end if
  set URL of current tab of front window to "https://example.com"
end tell' >/dev/null 2>&1
echo "Triggered Safari load at $(date +%H:%M:%S)" >> "$OUT"
echo "Triggering libcurl direct connect..." >> "$OUT"
curl -m 5 -sS -o /dev/null -w "curl example.com: HTTP %{http_code} in %{time_total}s\n" https://example.com >> "$OUT" 2>&1
sleep 3

log_section "7. FilterDataProvider logs since Safari load (last 30s)"
log show --predicate 'subsystem == "com.usetessera.mybrick" AND category == "FilterDataProvider"' --style compact --last 30s >> "$OUT" 2>&1

log_section "8. neagent + nesessionmanager last 30s"
sudo log show --predicate 'process == "neagent" OR process == "nesessionmanager"' --style compact --last 30s 2>&1 | tail -100 >> "$OUT"

log_section "9. Container app process list"
ps -ef | grep -E "FoqosMac|neagent|nesessionmanager" | grep -v grep >> "$OUT" 2>&1

echo "" >> "$OUT"
echo "Done. Output: $OUT" >> "$OUT"

cat "$OUT"
