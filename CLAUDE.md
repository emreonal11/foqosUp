# MyBrick — Development Guidelines

## What This Repo Is

A personalized fork of [Foqos](https://github.com/awaseem/foqos) — a free, open-source app blocker for iOS/iPadOS that uses NFC tags, QR codes, timers, and schedules to gate access to distracting apps.

Foqos already implements ~everything originally scoped for "MyBrick": NFC tag scanning, scheduled blocking, emergency unblock, multi-profile support, Screen Time API integration, Live Activities, widgets, and a polished UI. The only customization in this fork is **bundle identity** (team, bundle prefix, app-group) so the app installs under your Apple Developer account rather than the original maintainer's.

**Origin**: forked from `awaseem/foqos` at commit `5ac998f` (Foqos 1.32.4).

---

## Repo Layout

```
foqosUp/
├── Foqos/                    # Main app (upstream)
├── FoqosWidget/              # Widget extension (upstream)
├── FoqosDeviceMonitor/       # DeviceActivity extension (upstream)
├── FoqosShieldConfig/        # Shield UI extension (upstream)
├── foqos.xcodeproj/          # Xcode project (upstream + personalization)
├── scripts/
│   └── apply-mybrick-overrides.sh   # Reapplies personalization on a fresh clone
├── CLAUDE.md                 # This file
├── CLAUDE.md.archive         # Original planning doc (pre-fork)
└── .claude/                  # Local Claude Code settings
```

---

## Personalization (What's Different From Upstream)

A single text-substitution recipe, applied via `scripts/apply-mybrick-overrides.sh`:

| Upstream | MyBrick |
|---|---|
| `DEVELOPMENT_TEAM = YR54789JNV` | `5K5YSF2TWZ` (Tessera AI Limited) |
| `dev.ambitionsoftware.foqos*` (bundle prefix) | `com.usetessera.mybrick*` |
| `group.dev.ambitionsoftware.foqos` (app group) | `group.com.usetessera.mybrick` |

Affected files:
- `foqos.xcodeproj/project.pbxproj` (12× team, 12× bundle ID)
- `Foqos/foqos.entitlements`, `FoqosDeviceMonitor/...`, `FoqosShieldConfig/...`, `FoqosWidget/...`
- `Foqos/Models/Shared.swift:6` (UserDefaults suite name)

---

## Update Workflow

**Goal**: pull new Foqos releases without losing personalization.

```bash
# Standard update
git fetch upstream
git rebase upstream/main
# If pbxproj/entitlements/Shared.swift conflict (rare — only if upstream
# touches the same lines), resolve by re-applying the MyBrick value, then:
git rebase --continue
```

**If a rebase gets ugly** — nuke the personalization commit and rebuild it:
```bash
git fetch upstream
git reset --hard upstream/main
bash scripts/apply-mybrick-overrides.sh
git add -A
git commit -m "MyBrick personalization: bundle IDs, team, app group"
git push --force-with-lease origin main
```

The recipe script is the durable spec — git history is replaceable.

**Remotes**:
- `origin` → `https://github.com/emreonal11/foqosUp.git` (your fork)
- `upstream` → `https://github.com/awaseem/foqos.git` (upstream Foqos)

---

## Architecture Constraints

**iOS / iPadOS only.** Foqos depends on Apple frameworks that don't exist on macOS:
- `ManagedSettings` — applies the app shield. **No macOS equivalent.**
- `DeviceActivity` — schedules and event triggers. iOS-only.
- `CoreNFC` — no Mac hardware support anyway.

Extending blocking to macOS would require a **separate** Mac companion app using different mechanisms (NSWorkspace observer + terminate for apps, NEFilterDataProvider for websites). It cannot be a target inside this project — the framework imports won't compile on macOS. See conversation history for trade-offs if/when that becomes a project.

**iOS API limitations to keep in mind**:
- App selection uses opaque `ApplicationToken`s — can't extract bundle IDs, can't sync the *contents* of a blocklist across devices, only the *state*.
- 50-app picker limit (use allow-mode for >50).
- Phone app cannot be blocked (Apple policy).
- `NSUbiquitousKeyValueStore` sync is 10–20s typical, sometimes minutes; 1MB cap.

---

## Development Workflow

**Build**: open `foqos.xcodeproj` in Xcode 15+, select your iPhone, Cmd+R.

**Testing**:
- Simulator does **not** support NFC or Screen Time API — must test on real hardware.
- Free Apple Developer account = 7-day signing certs (re-deploy weekly).
- Test offline scenarios (airplane mode) — local blocking should still work.

**Before changes**: read existing Foqos code first. Most features you'd want are already implemented (`Foqos/Utils/StrategyManager.swift`, `Foqos/Models/BlockedProfiles.swift`, `Foqos/Utils/NFCScannerUtil.swift`). Avoid duplicating logic.

**Working with Foqos source**:
- Strategies live in `Foqos/Models/Strategies/` (NFC, QR, manual, timer, plus combinations)
- The shield UI is in `FoqosShieldConfig/ShieldConfigurationExtension.swift`
- Live Activities and timers are in `Foqos/Utils/LiveActivityManager.swift` and `Foqos/Models/Timers/`
- The shared cross-extension state container is `Foqos/Models/Shared.swift`

**Avoid**:
- Editing `apply-mybrick-overrides.sh` and existing patched files in the same commit — keep personalization isolated to one commit so rebases stay clean.
- Adding macOS targets — won't compile.
- Adding new features that should live upstream — open a PR against `awaseem/foqos` instead. Local fork is for personalization only.

---

## Recovery Cheatsheet

**"I lost my personalization commit"** — rerun the script:
```bash
bash scripts/apply-mybrick-overrides.sh
git add -A && git commit -m "MyBrick personalization"
```

**"Local repo is corrupt or I want a clean slate"**:
```bash
cd ~/projects
mv foqosUp foqosUp.broken
git clone https://github.com/emreonal11/foqosUp.git
# Fork already has the personalization commit, so it's good to go.
```

**"My fork is broken too"** — rebuild from upstream + the recipe:
```bash
cd ~/projects
git clone https://github.com/awaseem/foqos.git foqosUp
cd foqosUp
git remote rename origin upstream
git remote add origin https://github.com/emreonal11/foqosUp.git
# Recreate scripts/apply-mybrick-overrides.sh from CLAUDE.md.archive or git history
bash scripts/apply-mybrick-overrides.sh
git add -A && git commit -m "MyBrick personalization"
git push --force-with-lease origin main
```

---

## When To Update Foqos

Personal use, low-stakes — update when:
- A bug fix in upstream affects you
- A new feature you actually want lands
- It's been ~6 months and you feel like it

There's no obligation to track upstream. Foqos as of the fork point already does what you need.

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
