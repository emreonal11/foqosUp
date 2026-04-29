# MyBrick — Project Workspace

Two apps, one umbrella repo. iOS app (personalized fork of [Foqos](https://github.com/awaseem/foqos)) is the source of truth for blocking state. Mac companion app reads that state via iCloud and enforces website blocking on macOS via NEFilterDataProvider.

## Repo Layout

```
FoqosUp/
├── Foqos/                          # iOS app — personalized fork of awaseem/foqos
│   ├── Foqos/                      # main app target (upstream)
│   ├── FoqosWidget/                # widget extension (upstream)
│   ├── FoqosDeviceMonitor/         # DeviceActivity extension (upstream)
│   ├── FoqosShieldConfig/          # shield UI extension (upstream)
│   ├── foqos.xcodeproj/            # Xcode project (upstream + personalization)
│   └── ...                         # upstream README, LICENSE, AGENTS.md, etc.
├── FoqosMac/                       # Mac companion app — our own code
│   ├── FoqosMac.xcodeproj/         # (TBD — created in Mac scaffold phase)
│   ├── FoqosMac/                   # container app target
│   └── FoqosMacFilter/             # NEFilterDataProvider system extension
├── scripts/
│   └── apply-mybrick-overrides.sh  # idempotent personalization for Foqos/
├── CLAUDE.md                       # this file
├── CLAUDE.md.archive               # original planning doc (pre-fork)
└── .claude/                        # local Claude Code settings
```

**Origin**: Foqos forked from `awaseem/foqos` at commit `5ac998f` (Foqos 1.32.4, 2026).

---

## Architecture

### iOS as Single Source of Truth

The iOS app owns blocking state. It writes to `NSUbiquitousKeyValueStore` (iCloud KV) on every state transition. The Mac companion observes those keys.

iCloud KV contract:

| Key | Type | Set when |
|---|---|---|
| `mybrick.isBlocked` | Bool | session start/end |
| `mybrick.isBreakActive` | Bool | break start/end |
| `mybrick.isPauseActive` | Bool | pause start/end |
| `mybrick.activeBlocklistDomains` | Data (JSON `[String]`) | session start, domain edit |
| `mybrick.activeProfileId` | String? | session start/end (debug aid) |
| `mybrick.lastUpdated` | Double (Unix ts) | every write |

Effective Mac block decision:
```swift
shouldBlock(host) = isBlocked && !isBreakActive && !isPauseActive
                 && (domains contains host || host hasSuffix any domain)
```

### Mac filter — Chrome-aware

`NEFilterDataProvider` on macOS does **not** report hostnames for Chrome-based browsers (Chrome, Edge, Brave, Arc, Opera) — only IPs. To handle this, the System Extension uses two paths:

- **Path 1 (Safari, Firefox, Network.framework apps)**: read hostname from `flow.remoteEndpoint.hostname`, match, allow/drop
- **Path 2 (Chrome and friends)**: peek first 1KB of outbound bytes, parse TLS ClientHello, extract SNI extension, match, allow/drop

This works for any browser without user setup. ECH (Encrypted Client Hello) will eventually break Path 2; revisit when ECH adoption among major distractor sites exceeds ~30%. Not a 2026 concern.

---

## Personalization (vs upstream Foqos)

Single text-substitution recipe at `scripts/apply-mybrick-overrides.sh`. Substitutions:

| Upstream | MyBrick |
|---|---|
| `DEVELOPMENT_TEAM = YR54789JNV` | `5K5YSF2TWZ` (Tessera AI Limited) |
| `dev.ambitionsoftware.foqos*` (bundle prefix) | `com.usetessera.mybrick*` |
| `group.dev.ambitionsoftware.foqos` (app group) | `group.com.usetessera.mybrick` |

Affected files:
- `Foqos/foqos.xcodeproj/project.pbxproj`
- `Foqos/Foqos/foqos.entitlements`, `Foqos/FoqosDeviceMonitor/...`, `Foqos/FoqosShieldConfig/...`, `Foqos/FoqosWidget/...`
- `Foqos/Foqos/Models/Shared.swift:6`

The personalization commit is the single commit that makes `Foqos/` build under your team. Run `bash scripts/apply-mybrick-overrides.sh` after any re-vendor.

---

## Update Workflow

### Pulling Foqos updates

```bash
cd ~/projects/FoqosUp/Foqos
git fetch upstream
git rebase upstream/main
# If conflicts (rare — only if upstream touches the same lines as our personalization):
#   resolve by re-applying MyBrick values
git rebase --continue
```

If a rebase gets ugly, nuke and rebuild the personalization commit:
```bash
cd ~/projects/FoqosUp/Foqos
git fetch upstream
git reset --hard upstream/main
cd ..
bash scripts/apply-mybrick-overrides.sh
cd Foqos
git add -A
git commit -m "MyBrick personalization: bundle IDs, team, app group"
git push --force-with-lease origin main
```

### Foqos remotes
- `origin` → `https://github.com/emreonal11/foqosUp.git` (your fork — name not yet renamed to `FoqosUp` on GitHub)
- `upstream` → `https://github.com/awaseem/foqos.git`

### FoqosMac remote
- TBD when first pushed

---

## iOS API Constraints (won't change)

- `ManagedSettings`, `DeviceActivity`, `FamilyControls`, `CoreNFC` — iOS/iPadOS only. **No macOS equivalents** (verified through WWDC 2025 / macOS Tahoe 26).
- App selection uses opaque `ApplicationToken`s — can sync state, can't sync the *identity* of selected apps cross-device.
- Phone app cannot be blocked (Apple policy).
- 50-app picker limit; use allow-mode for >50.
- `NSUbiquitousKeyValueStore` sync: 10–20s typical, sometimes minutes; 1MB cap.

## macOS API Constraints

- `NEFilterDataProvider` does not give hostnames for Chrome-family browsers; SNI inspection required (handled).
- `NEDNSProxyProvider` is bypassed by Chrome's DoH; not used here.
- `EndpointSecurity` entitlement is gated to security vendors; not available.
- iCloud Private Relay routes Safari traffic in a way invisible to local content filters; only relevant if user uses Safari (we don't).

## Reference architectures

- iOS Foqos itself for the Screen Time / DeviceActivity patterns
- Apple's **SimpleFirewall** sample (WWDC19) — minimal NEFilterDataProvider on macOS
- **LuLu** by Patrick Wardle — production NETransparentProxyProvider/NEFilterDataProvider on macOS (https://github.com/objective-see/LuLu)

---

## Development Workflow

### iOS

```bash
cd ~/projects/FoqosUp/Foqos
open foqos.xcodeproj
# Connect iPhone via USB, Cmd+R
```

Real device required (no Simulator support for NFC, Screen Time, NetworkExtension). Free Apple Developer account = 7-day signing certs; paid ($99/yr) = 1-year. Same paid account covers iOS and macOS targets.

### Mac

```bash
cd ~/projects/FoqosUp/FoqosMac
open FoqosMac.xcodeproj
# Connect Mac as build target (or run on dev Mac)
# Cmd+R
# First run: macOS prompts for System Extension approval — approve in Privacy & Security
```

Apple Silicon required. Verified for macOS Tahoe 26.

### When stuck

System Extensions log to Console.app. Filter by subsystem `com.usetessera.mybrick`.

---

## Recovery Cheatsheet

**"I lost my personalization commit"** — rerun the script:
```bash
cd ~/projects/FoqosUp
bash scripts/apply-mybrick-overrides.sh
cd Foqos
git add -A && git commit -m "MyBrick personalization"
```

**"Local repo is corrupt"**:
```bash
cd ~/projects
mv FoqosUp FoqosUp.broken
git clone https://github.com/emreonal11/foqosUp.git FoqosUp
# Fork already has personalization, ready to use.
```

**"Need to rebuild from upstream + recipe"**:
```bash
cd ~/projects
git clone https://github.com/awaseem/foqos.git Foqos.fresh
mkdir FoqosUp && cd FoqosUp
mv ../Foqos.fresh Foqos
# Recreate scripts/apply-mybrick-overrides.sh from CLAUDE.md.archive or git history
git init
bash scripts/apply-mybrick-overrides.sh
git add -A && git commit -m "MyBrick personalization"
```

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
**Mac scaffold**: pending (Phase B in conversation history)
