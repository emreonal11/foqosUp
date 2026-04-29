#!/usr/bin/env bash
# Applies MyBrick personalization to a fresh clone of awaseem/foqos.
# Idempotent: safe to run multiple times.
#
# Layout assumption: this script lives at <repo-root>/scripts/, and the
# Foqos iOS source tree lives at <repo-root>/Foqos/. (Post-2026 reorg —
# see CLAUDE.md history if confused.)
#
# Usage:
#   bash scripts/apply-mybrick-overrides.sh
#
# When to run:
#   - First-time setup on a fresh clone
#   - After re-vendoring upstream Foqos into Foqos/ to rebuild personalization
#
# What it does:
#   1. Replaces upstream bundle ID prefix in Foqos/foqos.xcodeproj/project.pbxproj
#   2. Replaces upstream development team in same
#   3. Replaces upstream app-group identifier in 4 entitlements files
#   4. Replaces upstream app-group literal in Foqos/Foqos/Models/Shared.swift

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
  Foqos/foqos.xcodeproj/project.pbxproj

# ─── 2. Entitlements: app-group identifier ────────────────────────────────────
sed -i '' "s|${UPSTREAM_APP_GROUP}|${MYBRICK_APP_GROUP}|g" \
  Foqos/Foqos/foqos.entitlements \
  Foqos/FoqosDeviceMonitor/FoqosDeviceMonitor.entitlements \
  Foqos/FoqosShieldConfig/FoqosShieldConfig.entitlements \
  Foqos/FoqosWidget/FoqosWidgetExtension.entitlements

# ─── 3. Shared.swift: app-group literal ───────────────────────────────────────
sed -i '' "s|\"${UPSTREAM_APP_GROUP}\"|\"${MYBRICK_APP_GROUP}\"|g" \
  Foqos/Foqos/Models/Shared.swift

echo "✓ MyBrick overrides applied."
echo ""
echo "Next: open Foqos/foqos.xcodeproj in Xcode, build, and verify."
