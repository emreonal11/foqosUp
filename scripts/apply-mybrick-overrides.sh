#!/usr/bin/env bash
# Applies MyBrick personalization to a fresh clone of awaseem/foqos.
# Idempotent: safe to run multiple times.
#
# Usage:
#   bash scripts/apply-mybrick-overrides.sh
#
# When to run:
#   - First-time setup on a fresh clone
#   - After `git reset --hard upstream/main` to rebuild your personalization commit
#
# What it does:
#   1. Replaces upstream bundle ID prefix with your prefix in pbxproj
#   2. Replaces upstream development team with yours in pbxproj
#   3. Replaces upstream app-group identifier in 4 entitlements files
#   4. Replaces upstream app-group literal in Foqos/Models/Shared.swift

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# ─── Upstream values (awaseem/foqos) ──────────────────────────────────────────
UPSTREAM_TEAM="YR54789JNV"
UPSTREAM_BUNDLE_PREFIX="dev.ambitionsoftware.foqos"
UPSTREAM_APP_GROUP="group.dev.ambitionsoftware.foqos"

# ─── MyBrick values ───────────────────────────────────────────────────────────
MYBRICK_TEAM="5K5YSF2TWZ"
MYBRICK_BUNDLE_PREFIX="com.usetessera.mybrick"
MYBRICK_APP_GROUP="group.com.usetessera.mybrick"

# ─── 1. project.pbxproj: bundle prefix + development team ─────────────────────
sed -i '' \
  -e "s|${UPSTREAM_BUNDLE_PREFIX}|${MYBRICK_BUNDLE_PREFIX}|g" \
  -e "s|DEVELOPMENT_TEAM = ${UPSTREAM_TEAM};|DEVELOPMENT_TEAM = ${MYBRICK_TEAM};|g" \
  foqos.xcodeproj/project.pbxproj

# ─── 2. Entitlements: app-group identifier ────────────────────────────────────
sed -i '' "s|${UPSTREAM_APP_GROUP}|${MYBRICK_APP_GROUP}|g" \
  Foqos/foqos.entitlements \
  FoqosDeviceMonitor/FoqosDeviceMonitor.entitlements \
  FoqosShieldConfig/FoqosShieldConfig.entitlements \
  FoqosWidget/FoqosWidgetExtension.entitlements

# ─── 3. Shared.swift: app-group literal ───────────────────────────────────────
sed -i '' "s|\"${UPSTREAM_APP_GROUP}\"|\"${MYBRICK_APP_GROUP}\"|g" \
  Foqos/Models/Shared.swift

echo "✓ MyBrick overrides applied."
echo ""
echo "Next: open foqos.xcodeproj in Xcode, build, and verify."
