# MyBrick — Project Workspace

This file is the SSOT for understanding this entire project. Read it cold and you should be able to continue any unfinished work without further context.

---

## 1. What this is

**Goal**: Block distracting apps and websites across the user's iPhone, iPad, and Mac, controlled from a single physical NFC tag (the "Brick"). Cooperative self-blocking — the user is blocking themselves, not adversaries; bypass resistance is "low friction is enough" rather than "tamper-proof."

**Origin story**: User originally planned to build a custom blocker called "MyBrick" by forking [Foqos](https://github.com/awaseem/foqos). Mid-build, they discovered Foqos already implements ~99% of the iOS feature set they wanted (NFC strategies, schedules, multi-profile, emergency unblock, polished UI). So the project pivoted:

- **iOS/iPad**: keep the Foqos fork with minimal personalization (team, bundle IDs, app group)
- **macOS**: build a small custom companion app that reads iOS state via iCloud and enforces website blocking on the Mac

**The user's personal context**:
- Has paid Apple Developer account ($99/yr), team `5K5YSF2TWZ` (Tessera AI Limited)
- iPhone running iOS 18+
- Mac: Apple Silicon, macOS Tahoe 26
- Browser: **Chrome only** (does not use Safari)
- Does **not** want to touch iCloud Private Relay
- Prefers minimal setup friction
- Wants iOS Foqos as the Single Source of Truth for both phone and Mac
- Wants emergency override on Mac (in case iCloud is broken or iPhone is dead)

---

## 2. Repo layout

```
~/projects/FoqosUp/                              ← this dir, the workspace + git repo
├── Foqos/                                       ← iOS fork (re-vendor via recipe)
│   ├── Foqos/                                   ← main iOS app (upstream Foqos)
│   ├── FoqosWidget/                             ← widget extension (upstream)
│   ├── FoqosDeviceMonitor/                      ← DeviceActivity extension (upstream)
│   ├── FoqosShieldConfig/                       ← shield UI extension (upstream)
│   ├── foqos.xcodeproj/                         ← Xcode project (upstream + personalization)
│   ├── foqosTests/, AGENTS.md, README.md, ...   ← upstream repo content
├── FoqosMac/                                    ← Mac companion app (planned, just placeholder README)
├── scripts/
│   └── apply-mybrick-overrides.sh               ← idempotent personalization recipe
├── CLAUDE.md                                    ← this file
├── CLAUDE.md.archive                            ← original planning doc (pre-Foqos discovery)
└── .claude/                                     ← local Claude Code settings
```

**GitHub**: https://github.com/emreonal11/FoqosUp (renamed from foqosUp 2026)

**Foqos remotes** (configured at the FoqosUp/ git repo level, not inside Foqos/):
- `origin` → https://github.com/emreonal11/FoqosUp.git
- `upstream` → https://github.com/awaseem/foqos.git

⚠️ The `upstream` remote can't be used with `git rebase upstream/main` directly because upstream's tree lives at the *root* of awaseem/foqos but our copy lives at `Foqos/` inside this repo. **Update workflow uses the re-vendor + recipe pattern instead** (see §9).

---

## 3. Architecture

### High-level flow

```
NFC scan on iPhone
  → Foqos starts session (Screen Time API blocks apps locally)
  → Hooks in SharedData setters write to NSUbiquitousKeyValueStore
  → iCloud syncs to Mac (~10–20s)
  → FoqosMac container app observes the change
  → Mirrors state to App Group UserDefaults
  → Posts Darwin notification
  → System Extension reads new state
  → On each new TCP/UDP flow, decides allow vs drop
```

### Why NEFilterDataProvider over alternatives

| Mechanism | Why not |
|---|---|
| NEFilterDataProvider ✓ | **Chosen.** Purpose-built for allow/deny on flows. Per-flow `handleNewFlow` returns `.allow()` / `.drop()`. Read-only access. Sample: Apple `SimpleFirewall`. |
| NETransparentProxyProvider | Designed for *proxying* flows (rewriting), not filtering. 3× heavier code. |
| NEDNSProxyProvider | Bypassed by Chrome's DoH and any DoH/DoT system DNS server. Doesn't help us. |
| NEFilterPacketProvider | Layer-2 packet inspection. Way too low-level for hostname blocking. |
| `/etc/hosts` + pf | Bypassed by DoH-using browsers, iCloud Private Relay, HTTP/2 connection coalescing. Not robust. |
| macOS Screen Time API | **Does not exist** for third parties. FamilyControls/ManagedSettings are iOS-only. Verified through WWDC 2025 / macOS Tahoe 26. |
| Configuration profile (webcontent-filter) | Only works in Safari (Chrome ignores). User uses Chrome. |
| Endpoint Security framework | Entitlement gated to security vendors; not available to solo dev. |

### The Chrome problem (decisive)

`NEFilterDataProvider.flow.remoteEndpoint.hostname` returns:
- The **hostname** for Safari, Firefox, and apps using NSURLSession / Network.framework
- Only the **IP address** for Chrome, Edge, Brave, Arc, Opera (Chromium-based browsers do their own DNS, often DoH, then connect by IP)

User is Chrome-only. So we cannot rely on `flow.remoteEndpoint.hostname` for the primary path.

**Solution**: SNI inspection. When `handleNewFlow` is called with an IP-only flow, return `.filterDataVerdict(peekOutboundBytes: 1024)`. The system then calls `handleOutboundDataFromFlow` with the first 1KB of outbound data. Parse the TLS ClientHello to extract the SNI extension (which carries the destination hostname in plaintext for non-ECH connections). Match against blocklist.

ECH (Encrypted Client Hello) defeats SNI inspection but is multi-year horizon. Cloudflare-fronted sites have it; Instagram/YouTube/X/TikTok/Reddit do not as of 2026.

### Container ↔ Extension IPC

Standard Apple pattern:
- Container app writes state to `UserDefaults(suiteName: "group.com.usetessera.mybrick")`
- Container posts a Darwin notification: `CFNotificationCenterPostNotification` with name `"com.usetessera.mybrick.state.changed"`
- Extension observes the notification, re-reads UserDefaults, updates internal blocklist

No XPC service needed.

### iOS as SSOT, Mac as read-only observer

The contract: **iOS writes, Mac reads.** No conflict resolution needed because there's only one writer.

Mac's emergency override is **local-only** (Keychain PIN), does NOT write to iCloud. So a Mac-side override doesn't interfere with iOS's view of state.

---

## 4. iCloud KV contract (the bridge)

Identifier in entitlements:
```
com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)com.usetessera.mybrick
```

The `$(TeamIdentifierPrefix)` form (NOT `$(CFBundleIdentifier)`) is required for cross-platform sharing between iOS and Mac apps with the same team.

### Keys

| Key | Type | Written by iOS on... | Read by Mac for... |
|---|---|---|---|
| `mybrick.isBlocked` | Bool | session start (true) / end (false) | gate decision |
| `mybrick.isBreakActive` | Bool | break start/end | suspend enforcement |
| `mybrick.isPauseActive` | Bool | pause start/end | suspend enforcement |
| `mybrick.activeBlocklistDomains` | Data (JSON `[String]`) | session start, profile domain edit during active session | match against |
| `mybrick.activeProfileId` | String? | session start (UUID) / end (nil) | debug aid |
| `mybrick.lastUpdated` | Double (Unix ts) | every write | staleness detection |

### Mac block decision

```swift
shouldBlock(host: String) -> Bool {
    guard isBlocked, !isBreakActive, !isPauseActive else { return false }
    let h = host.lowercased()
    return domains.contains { h == $0 || h.hasSuffix(".\($0)") }
}
```

Suffix match means blocking `youtube.com` also blocks `m.youtube.com`, `studio.youtube.com`, etc.

### Pause vs break (resolved)

Pause is a separate state from break in iOS Foqos, but **functionally identical for our purposes**: both call `appBlocker.deactivateRestrictionsForBreak(...)` to lift restrictions. So both should also unblock on Mac.

Pause/break start/end transitions happen in the **`FoqosDeviceMonitor` extension** (not the main app), via DeviceActivity callbacks (`intervalDidStart` / `intervalDidEnd`). The extension calls `SharedData` setters, so hooking those setters covers both contexts.

---

## 5. iOS state model — key files & hook points

All paths relative to `~/projects/FoqosUp/Foqos/`.

### Key files

- `Foqos/Models/Shared.swift` — `SharedData` enum holding all snapshots in app-group UserDefaults. **Primary hook target.**
- `Foqos/Models/BlockedProfiles.swift` — profile model. `domains: [String]?` field on `ProfileSnapshot`.
- `Foqos/Models/BlockedProfileSessions.swift` — session model. `isActive`, `isBreakActive`, `isPauseActive` derived properties.
- `Foqos/Models/Timers/PauseTimerActivity.swift` — pause `.start()` calls `deactivateRestrictionsForBreak`. Runs in extension.
- `Foqos/Models/Timers/BreakTimerActivity.swift` — break analog. Runs in extension.
- `Foqos/Models/Timers/TimerActivityUtil.swift` — dispatcher.
- `Foqos/Utils/StrategyManager.swift` — top-level checks: `isBlocking`, `isBreakActive`, `isPauseActive`.
- `Foqos/Utils/AppBlockerUtil.swift` — applies/deactivates restrictions via `ManagedSettings`.
- `FoqosDeviceMonitor/DeviceActivityMonitorExtension.swift` — DeviceActivity callbacks dispatcher.

### Single active session invariant

```swift
// BlockedProfileSessions.swift:114
static func mostRecentActiveSession(in context: ModelContext) -> BlockedProfileSession? {
    var descriptor = FetchDescriptor<BlockedProfileSession>(
        predicate: #Predicate { $0.endTime == nil },
        sortBy: [SortDescriptor(\.startTime, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
}
```

`StrategyManager` enforces "only one active session at a time" — starting a new one stops the old.

### Hook points for iCloud writes

All in `Shared.swift` setters. Hooking here covers both the main app and the FoqosDeviceMonitor extension, because both call the same setters.

| Setter | Triggers |
|---|---|
| `createActiveSharedSession(_:)` | session start (NFC/QR/manual strategies, via `BlockedProfileSessions.createSession`) → write `isBlocked=true`, profileId, domains, reset break/pause flags |
| `createSessionForSchedular(for:)` | session start (DeviceActivity-driven scheduled blocks, via `ScheduleTimerActivity.start`) → same payload as `createActiveSharedSession` |
| `flushActiveSession()` | session end (NFC/QR/manual strategies, via `BlockedProfileSessions.endSession`) → write `isBlocked=false`, clear profileId/domains, reset break/pause |
| `endActiveSharedSession()` | session end (DeviceActivity-driven schedule end + strategy timer expiry, via `ScheduleTimerActivity.stop`/`StrategyTimerActivity.stop`) → same payload as `flushActiveSession` |
| `setBreakStartTime(date:)` | break start → write `isBreakActive=true` |
| `setBreakEndTime(date:)` | break end → write `isBreakActive=false` |
| `setPauseStartTime(date:)` | pause start → write `isPauseActive=true` |
| `setPauseEndTime(date:)` | pause end → write `isPauseActive=false` |
| `setSnapshot(_:for:)` | profile updated → if profile == active session's profile, write updated `domains` |

Why 9 hooks, not 7: there are two parallel session-lifecycle paths in the codebase. `BlockedProfileSessions.createSession`/`endSession` (driven by NFC, QR, and manual strategies) call `createActiveSharedSession`/`flushActiveSession`. The DeviceActivity-driven paths (scheduled blocks, strategy timer expiry) instead call `createSessionForSchedular`/`endActiveSharedSession` from inside the FoqosDeviceMonitor extension. Hooking only the first pair leaves Mac state stuck whenever a session begins or ends via a timer. The break/pause setters are shared by both contexts.

Domain updates during an active session need the `setSnapshot` hook because users can edit their blocklist mid-session. The `setSnapshot` hook checks `if let activeSession, activeSession.blockedProfileId.uuidString == profileID { ... }`.

Setters intentionally NOT hooked: `setEndTime(date:)` only writes the `endTime` field on the SessionSnapshot for the completed-sessions archive — it's called immediately before `flushActiveSession` and the iCloud cleanup happens there. `resetPause()` clears `pauseStartTime`/`pauseEndTime` on the snapshot before `setPauseStartTime` writes the new values; the pause-start hook handles iCloud state. `removeSnapshot(for:)` is profile deletion via UI — not a session lifecycle event.

### Implementation choice: inline, no new file

The bridge code is **inlined into `Shared.swift`** as a private helper, not a separate file. Reason: a new file would need to be added to all 4 Xcode targets (Foqos main, FoqosWidget, FoqosDeviceMonitor, FoqosShieldConfig), which requires touching `project.pbxproj` for each target. Inlining sidesteps this entirely.

---

## 6. macOS Mac app — architecture

### Targets (planned final layout)

```
FoqosMac.xcodeproj/
├── FoqosMac/                  ← container app (SwiftUI MenuBarExtra)
│   ├── FoqosMacApp.swift      ← @main, MenuBarExtra (DONE, Phase B)
│   ├── ContentView.swift      ← state-display dropdown UI (DONE, Phase B)
│   ├── BridgeState.swift      ← ObservableObject (TODO Phase C: split out of FoqosMacApp.swift)
│   ├── ICloudObserver.swift   ← NSUbiquitousKeyValueStore listener (TODO Phase C: split out)
│   ├── ExtensionActivator.swift  ← OSSystemExtensionRequest flow (TODO Phase C)
│   ├── AppGroupBridge.swift   ← writes state to App Group, posts Darwin notification (TODO Phase C)
│   ├── EmergencyOverride.swift   ← PIN UI + Keychain storage (TODO Phase E)
│   └── FoqosMac.entitlements  ← KV + App Group (DONE Phase B); add NE + SE for Phase C
└── FoqosMacFilter/            ← System Extension (TODO Phase C — entire target doesn't exist yet)
    ├── FilterDataProvider.swift   ← NEFilterDataProvider subclass
    ├── FilterControlProvider.swift ← NEFilterControlProvider stub
    ├── SNIParser.swift            ← TLS ClientHello SNI extraction (Phase D)
    ├── BlocklistMatcher.swift     ← exact + suffix matching
    └── FoqosMacFilter.entitlements
```

**Current reality (post-Phase B)**: `BridgeState` + `ICloudObserver` + `BridgeKey` are all inlined in `FoqosMacApp.swift`. The Phase B build was done before we realized the project uses synchronized file groups — see next note. Splitting them is a Phase C cleanup that also clears the SourceKit "main attribute / top-level code" lint warning.

**Synchronized file groups (`PBXFileSystemSynchronizedRootGroup`)**: `FoqosMac.xcodeproj` was created with Xcode 26.x and uses `objectVersion = 77`, which gives each target a synchronized root group. Any Swift file dropped into the target's source directory (e.g. `FoqosMac/FoqosMac/`) is auto-included in the build — **no `project.pbxproj` edit required**. This applies to the container target today and (when Xcode keeps the same default for new targets) will apply to `FoqosMacFilter` once it's added. Adding a new *target* still requires Xcode's GUI; adding new *files* inside an existing target does not. This contrasts with the iOS Foqos project (§5), which uses the traditional file-reference pattern — that's why the iOS bridge was inlined into `Shared.swift`.

### Container app entitlements

Phase B (done):
- `com.apple.developer.ubiquity-kvstore-identifier` = `$(TeamIdentifierPrefix)com.usetessera.mybrick` (same as iOS — **must NOT default to `$(CFBundleIdentifier)`**, that creates a per-bundle namespace which iOS can't reach)
- `com.apple.security.app-sandbox` = `true`
- `com.apple.security.application-groups` = `[group.com.usetessera.mybrick]`

Phase C (to add):
- `com.apple.developer.networking.networkextension` = `[content-filter-provider-systemextension]`
- `com.apple.developer.system-extension.install` = `true`

### Extension entitlements (Phase C)

- `com.apple.security.application-groups` = `[group.com.usetessera.mybrick]`
- `com.apple.developer.networking.networkextension` = `[content-filter-provider-systemextension]`

⚠️ **Critical**: when adding the iCloud capability via Xcode's `+ Capability` dialog, the search for "iCloud" returns BOTH `iCloud` and `iCloud Extended Share Access`. Only the first is wanted. The second is a separate macOS Tahoe capability for in-process app sharing — adds noise + can interfere with provisioning. If accidentally added, click the trash icon on its capability row to remove.

### NEFilterDataProvider behavior on macOS

- System Extension model (NOT app extension) — runs as privileged service after user approval
- "supervised device only" docs apply to iOS, NOT macOS
- `handleNewFlow(NEFilterFlow)` returns one of:
  - `.allow()` — allow flow without further inspection
  - `.drop()` — block at TCP layer, browser shows "can't connect"
  - `.filterDataVerdict(withFilterInbound: false, peekInboundBytes: 0, filterOutbound: true, peekOutboundBytes: 1024)` — request to peek at outbound data

### The two-path matching strategy

```swift
override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    guard let socketFlow = flow as? NEFilterSocketFlow,
          let endpoint = socketFlow.remoteEndpoint as? NWHostEndpoint
    else { return .allow() }
    
    let host = endpoint.hostname
    
    if isIPAddress(host) {
        // Path 2: Chrome — peek outbound bytes for SNI inspection
        return .filterDataVerdict(
            withFilterInbound: false,
            peekInboundBytes: 0,
            filterOutbound: true,
            peekOutboundBytes: 1024
        )
    }
    
    // Path 1: Safari/Firefox/NSURLSession — direct hostname match
    return BlocklistMatcher.shouldBlock(host) ? .drop() : .allow()
}

override func handleOutboundData(from flow: NEFilterFlow,
                                 readBytesStartOffset: Int,
                                 readBytes: Data) -> NEFilterDataVerdict {
    if let sni = SNIParser.extractSNI(from: readBytes) {
        return BlocklistMatcher.shouldBlock(sni) ? .drop() : .allow()
    }
    return .allow()  // Couldn't parse — fail open
}
```

### Apple Developer portal setup needed

1. App ID for `com.usetessera.mybrick.FoqosMac` (container)
2. App ID for `com.usetessera.mybrick.FoqosMacFilter` (extension)
3. Network Extensions capability enabled on both
4. iCloud KV capability enabled on container
5. App Group `group.com.usetessera.mybrick` shared with both
6. Provisioning profiles regenerated

Most of this is automatic via Xcode's "automatic signing" once entitlements are configured. Some require manual portal clicks (Network Extensions capability sometimes needs an email request to networkextension@apple.com — not always required for solo dev personal apps; try Xcode auto first, only request if denied).

### First-time install UX

1. User downloads/builds .app
2. Drag to /Applications
3. First launch: SwiftUI menu bar icon appears
4. Click menu → "Enable Mac Blocking"
5. App calls `OSSystemExtensionRequest.activationRequest(...)`
6. macOS shows "System Extension Blocked" notification
7. User opens System Settings → Privacy & Security → unlocks → clicks Allow next to FoqosMacFilter
8. Network filter prompt: "Allow FoqosMac to filter network content?" → Allow
9. Filter active

### Emergency override

- 4-digit PIN set on first launch
- Stored in macOS Keychain (not iCloud, not App Group)
- Disables filter locally without writing to iCloud (so iOS state stays "blocked" even when Mac is unblocked)
- Re-arms on next iCloud state change OR after timeout (TBD)

### Login at startup

`SMAppService.mainApp.register()` (macOS Ventura+ API). User can manage in System Settings → Login Items. Bundles a LaunchAgent inside the .app for cleanliness.

---

## 7. Personalization recipe (Foqos)

The user's iOS app diverges from upstream Foqos in exactly three string substitutions:

| Upstream | MyBrick |
|---|---|
| `DEVELOPMENT_TEAM = YR54789JNV` | `5K5YSF2TWZ` |
| `dev.ambitionsoftware.foqos*` (bundle prefix) | `com.usetessera.mybrick*` |
| `group.dev.ambitionsoftware.foqos` (app group) | `group.com.usetessera.mybrick` |

**Plus, after Phase A**: iCloud KV identifier added to all 4 entitlements files.

### Affected files (paths from FoqosUp/ root)

- `Foqos/foqos.xcodeproj/project.pbxproj`
- `Foqos/Foqos/foqos.entitlements`
- `Foqos/FoqosWidget/FoqosWidgetExtension.entitlements`
- `Foqos/FoqosDeviceMonitor/FoqosDeviceMonitor.entitlements`
- `Foqos/FoqosShieldConfig/FoqosShieldConfig.entitlements`
- `Foqos/Foqos/Models/Shared.swift:6` (UserDefaults suite name literal)

### Running the recipe

```bash
cd ~/projects/FoqosUp
bash scripts/apply-mybrick-overrides.sh
```

Idempotent. Safe to run multiple times.

---

## 8. Key technical facts (verified)

These were independently verified during research; treat as ground truth unless macOS/Apple changes:

### iOS API constraints (don't fight these)

- `ManagedSettings`, `DeviceActivity`, `FamilyControls`, `CoreNFC` — **iOS/iPadOS only**, no macOS equivalent. Verified through WWDC 2025 / macOS Tahoe 26.
- App selection uses opaque `ApplicationToken`s — can sync state, can't sync the *identity* of selected apps cross-device.
- Phone app cannot be blocked (Apple policy).
- 50-app picker limit; use allow-mode for >50.
- `NSUbiquitousKeyValueStore` sync: 10–20s typical, sometimes minutes; 1MB cap (we use ~5KB).

### macOS API facts

- `NEFilterDataProvider` runs as System Extension on macOS (not app extension); no supervision required.
- `NEFilterDataProvider.flow.url` is **nil** for non-WebKit browsers — Chrome flows have no URL info.
- `NEFilterDataProvider.flow.remoteEndpoint.hostname` returns hostname for Safari/Firefox/NSURLSession; returns IP for Chrome.
- `NEDNSProxyProvider` is bypassed by Chrome's DoH (default on in 2026) and by any DoH/DoT system DNS.
- `EndpointSecurity` entitlement gated to security vendors — not available.
- iCloud Private Relay routes Safari traffic invisibly to local content filters; **not relevant since user uses Chrome**.
- Apple's `SimpleFirewall` (WWDC19) is the canonical NEFilterDataProvider sample.
- LuLu (https://github.com/objective-see/LuLu) is a production reference for NETransparentProxyProvider on macOS.
- VPN install order matters: install filter BEFORE VPN client. Reverse may bypass.
- SNI is plaintext in TLS ClientHello until ECH is widely deployed; ECH adoption among major distractor sites (Instagram, YouTube, X, Reddit, TikTok) is ~zero in 2026.

### Apple Silicon / macOS Tahoe 26

- Standard $99/yr account suffices; Personal Team (free) cannot ship System Extensions.
- WWDC25 added enterprise URL filtering with OHTTP relay — not relevant to us.
- SystemExtension activation flow unchanged from Sequoia.
- SMAppService for login-at-startup works as on Ventura+.

---

## 9. Update workflow (Foqos)

⚠️ Standard `git rebase upstream/main` does NOT work because our copy is at `Foqos/` while upstream is at root. Use the recipe pattern instead:

### Re-vendor upstream into Foqos/

```bash
cd ~/projects/FoqosUp

# 1. Save the existing Foqos tree
mv Foqos Foqos.old

# 2. Clone fresh upstream into Foqos/
git clone https://github.com/awaseem/foqos.git Foqos

# 3. Re-apply MyBrick personalization
bash scripts/apply-mybrick-overrides.sh

# 4. Commit
git add -A
git commit -m "Update Foqos to upstream X.Y.Z"
git push

# 5. Verify build, then clean up
open Foqos/foqos.xcodeproj  # build to phone, verify
rm -rf Foqos.old
```

### Frequency
Personal use, low-stakes. Update when:
- A bug fix in upstream affects you
- A new feature you want lands
- ~6 months elapsed and you feel like it

There's no obligation to track upstream.

---

## 10. Recovery cheatsheet

**"I lost my personalization commit"**:
```bash
cd ~/projects/FoqosUp
bash scripts/apply-mybrick-overrides.sh
git add -A && git commit -m "MyBrick personalization"
git push
```

**"Local repo is corrupt"**:
```bash
cd ~/projects
mv FoqosUp FoqosUp.broken
git clone https://github.com/emreonal11/FoqosUp.git
# Fork has personalization, ready to use.
```

**"Need to rebuild from upstream + recipe"**:
```bash
cd ~/projects
git clone https://github.com/awaseem/foqos.git Foqos.fresh
mkdir FoqosUp.new && cd FoqosUp.new
mv ../Foqos.fresh Foqos
git init
# Manually copy scripts/ and CLAUDE.md back from CLAUDE.md.archive or backup
bash scripts/apply-mybrick-overrides.sh
git add -A && git commit -m "Bootstrap"
```

---

## 11. Where we are right now (execution state)

**Done**:
- ✅ iOS Foqos fork at FoqosUp/Foqos/ — built and installed on user's iPhone
- ✅ Personalization recipe (`scripts/apply-mybrick-overrides.sh`)
- ✅ Repo migration: foqosUp → FoqosUp/Foqos + FoqosUp/FoqosMac sibling layout
- ✅ Pushed to GitHub, repo renamed foqosUp → FoqosUp
- ✅ All architectural decisions made and verified
- ✅ Pause semantics fully understood
- ✅ Chrome SNI inspection plan finalized

**Done (Phase A — iOS bridge)**:
- ✅ Added `com.apple.developer.ubiquity-kvstore-identifier` entitlement to all 4 iOS targets
- ✅ Inlined `ICloudStateBridge` helper into `Foqos/Foqos/Models/Shared.swift` with hooks in 9 setters: `createActiveSharedSession`, `createSessionForSchedular`, `flushActiveSession`, `endActiveSharedSession`, `setBreakStartTime`, `setBreakEndTime`, `setPauseStartTime`, `setPauseEndTime`, `setSnapshot` (see §5 for full table + rationale)
- ✅ Updated `scripts/apply-mybrick-overrides.sh` with idempotent PlistBuddy block to inject the entitlement on re-vendor
- ✅ Xcode capability + provisioning profile regeneration completed for all 4 targets
- ✅ Verified on device: NFC scan triggers `sessionStarted profile=… domains=…` log under subsystem `com.usetessera.mybrick`, category `iCloudBridge`. Commit `d73ae06`.

**Done (Phase B — Mac container app reading iCloud)**:
- ✅ Xcode project at `FoqosUp/FoqosMac/FoqosMac.xcodeproj` (macOS App template, SwiftUI, App Sandbox + Hardened Runtime on)
- ✅ Bundle ID `com.usetessera.mybrick.FoqosMac`, team `5K5YSF2TWZ`, deployment target macOS 26.3
- ✅ Capabilities: iCloud (Key-value storage) + App Groups (`group.com.usetessera.mybrick`)
- ✅ Critical fix: KV identifier in `FoqosMac.entitlements` overridden from Xcode default `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` → `$(TeamIdentifierPrefix)com.usetessera.mybrick` to match iOS namespace exactly
- ✅ App skeleton: `FoqosMacApp.swift` (@main + `BridgeState` ObservableObject + `ICloudObserver`), `ContentView.swift` (state-display UI)
- ✅ MenuBarExtra UI: lock icon (filled when blocked, open when not) + dropdown panel showing all 6 bridge keys + Force-sync/Quit buttons
- ✅ Verified end-to-end: bricking iPhone flips Mac menu bar icon + populates panel within **1–2s** (much faster than the 10–20s estimate; iCloud is performant when not under load). Domains list shows `instagram.com`. Profile UUID matches iOS.

Observed behavior worth noting:
- iCloud KV `didChangeExternallyNotification` reason `0` (= `NSUbiquitousKeyValueStoreServerChange`, remote write) fires reliably on every brick/unbrick.
- iCloud sync latency under typical conditions: ~1–2 seconds. CLAUDE.md §8 says "10–20s typical, sometimes minutes" — that's the worst-case. In practice it's near-realtime.

Known cosmetic issue (non-blocking, not a real compile error):
- `FoqosMacApp.swift` triggers a SourceKit lint warning "main attribute cannot be used in a module that contains top-level code" because `@main struct FoqosMacApp` shares the file with `BridgeState`, `ICloudObserver`, and `BridgeKey`. Compiler accepts it; the IDE indexer is just grumpy. Cleanup task for Phase C: split into separate files. Because the project uses synchronized file groups (see §6), this is just a file-system operation — no `project.pbxproj` edit needed.

**Pending (Phase C — System Extension that actually blocks)**:

Goal: Mac drops TCP connections to blocklisted hosts when iOS state says blocked. End-to-end: NFC scan on iPhone → iCloud → FoqosMac container → App Group + Darwin notification → FoqosMacFilter extension → `NEFilterDataProvider.handleNewFlow` returns `.drop()` for matching flows.

Sub-milestones (commit each separately):

1. **Add `FoqosMacFilter` System Extension target to `FoqosMac.xcodeproj`**
   - Xcode: File → New → Target → macOS → Network Extension
   - Provider type: Content Filter Provider
   - Bundle ID: `com.usetessera.mybrick.FoqosMac.FoqosMacFilter` (must be a sub-identifier of the container — Apple requires this for sysextensions)
   - Add `App Groups` capability with `group.com.usetessera.mybrick`
   - Configure entitlements per §6 "Extension entitlements"
   - Container target gets `com.apple.developer.networking.networkextension` and `com.apple.developer.system-extension.install` added (per §6 "Container app entitlements" Phase C section)

2. **Apple Developer portal capability check**
   - Xcode automatic signing should auto-register the new App ID and add Network Extensions capability for personal team use
   - If "Network Extensions capability not found" red error persists past 60s, may need to email networkextension@apple.com requesting the capability (NOT usually required for solo dev personal apps; try Xcode auto first)
   - PLA acceptance gotcha may resurface for the new App ID — same fix as Phase A: developer.apple.com → accept agreement → quit and reopen Xcode

3. **Container: ExtensionActivator (Swift, in container app target)**
   - Use `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)` with the filter's bundle ID
   - Handle delegate callbacks: `request(_:actionForReplacingExtension:with:)` returns `.replace`; `request(_:didFinishWithResult:)` checks `.completed` vs `.willCompleteAfterReboot`; `request(_:didFailWithError:)` for retries
   - Surface state to BridgeState so the menu bar UI can show "Filter active / inactive / needs approval"
   - Add a button in `ContentView.swift` to trigger activation on first launch

4. **Extension: hardcoded-block first milestone**
   - `FilterDataProvider.swift` subclass of `NEFilterDataProvider`
   - In `startFilter`: install a `NEFilterRule` matching all flows (or `NEFilterSettings(rules: [], defaultAction: .filterData)`) so all new flows are routed through `handleNewFlow`
   - In `handleNewFlow`: if the flow's hostname == hardcoded `"example.com"`, return `.drop()`. Else `.allow()`
   - **Verification command**: in Terminal: `curl -v --max-time 5 https://example.com` — should fail with "Couldn't connect to server" or similar TCP-level error. `curl https://google.com` should still succeed.
   - This proves the system extension plumbing works without depending on iCloud/AppGroup/Darwin notification yet.

5. **Container ↔ Extension IPC (App Group + Darwin notification)**
   - `AppGroupBridge.swift` in container app: subscribes to `BridgeState`'s `objectWillChange`, when state changes writes the relevant fields (`isBlocked`, `isBreakActive`, `isPauseActive`, `domains`) to `UserDefaults(suiteName: "group.com.usetessera.mybrick")`
   - After the write: `CFNotificationCenterPostNotification` with name `"com.usetessera.mybrick.state.changed"` (Darwin notification, system-wide)
   - In the extension: `CFNotificationCenterAddObserver` with the same notification name, callback re-reads UserDefaults and updates an in-memory blocklist
   - Replace the hardcoded `"example.com"` check with a lookup against the in-memory list

6. **Verify end-to-end**
   - With iPhone unblocked: `curl https://instagram.com` succeeds
   - Brick on iPhone (with `instagram.com` in domains list)
   - Wait ~2-3s (iCloud + container update + Darwin notification)
   - `curl https://instagram.com` should now fail
   - Unbrick → curl works again

**Phase C does NOT include**: Chrome SNI inspection (Phase D — Chrome's IP-only flows need TLS ClientHello parsing); user-facing UI for managing the filter beyond a basic toggle; emergency override (Phase E). Phase C is about proving the kill-switch plumbing works for the simple Safari/curl/NSURLSession case.

**Pending (Phase D — Chrome SNI inspection)**:
1. Detect IP-only flows (when `flow.remoteEndpoint.hostname` is an IP address, see §3 "Chrome problem")
2. Return `.filterDataVerdict(peekOutboundBytes: 1024)` for those flows
3. Implement `handleOutboundData(from:readBytesStartOffset:readBytes:)` to parse TLS ClientHello and extract SNI
4. SNI parser: ~50 LOC of Swift, RFC 8446 §4.1.2 + RFC 6066 §3 — see §14 for reference
5. Real-world test: open Instagram in Chrome with phone bricked → should hit "can't connect"

**Pending (Phase E — Polish)**:
1. SMAppService login-at-startup (`SMAppService.mainApp.register()`)
2. Custom menu bar icon (currently uses SF Symbol `lock.fill` / `lock.open`)
3. `LSUIElement = true` in Info.plist to hide Dock icon (currently shows in both Dock + menu bar)
4. Emergency override (4-digit PIN in Keychain, local-only, doesn't write to iCloud — see §6)
5. Notarize for personal use (avoids Gatekeeper warnings on rebuild)
6. Custom AppIcon (currently default Xcode template)

### Cross-cutting learnings from Phase A & B (preserve for future sessions)

- **iCloud KV sync latency in practice**: ~1–2 seconds for KV updates between iPhone and Mac on the same Apple ID. CLAUDE.md §8's "10–20s typical" is the worst-case docs figure; real-world is much faster. Don't over-engineer for slow sync.
- **`NSUbiquitousKeyValueStore.didChangeExternallyNotification` reason codes seen**: `0` = `NSUbiquitousKeyValueStoreServerChange` (remote write — what we want), `1` = `NSUbiquitousKeyValueStoreInitialSyncChange` (fires once at app launch). Both should trigger a refresh.
- **The KV identifier override** is the single most important Phase B detail. Xcode's default `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` creates a *per-bundle* namespace; iOS and Mac end up unable to see each other. Override to `$(TeamIdentifierPrefix)com.usetessera.mybrick` on both sides. The `apply-mybrick-overrides.sh` script handles this for iOS; Mac has it set manually in `FoqosMac/FoqosMac/FoqosMac.entitlements`.
- **Swift 6 strict concurrency on macOS Tahoe**: `@MainActor final class Foo: ObservableObject` with `@Published` properties requires explicit `import Combine` even though SwiftUI re-exports it. Without the import, you get "Initializer 'init(wrappedValue:)' is not available due to missing import of defining module 'Combine'" — for every `@Published`.
- **SourceKit "main attribute cannot be used in a module that contains top-level code"**: this triggers when `@main struct App` shares a file with other top-level declarations (classes, structs, enums). It's a lint warning, not a compile error — the build succeeds. Fix is cosmetic: split into multiple files. With `PBXFileSystemSynchronizedRootGroup` (Xcode 26.x default, see §6), this is purely a file-system move — no `project.pbxproj` edit required.
- **PLA acceptance**: Apple periodically updates the Program License Agreement. When pending, ALL Xcode signing operations fail with "Unable to process request - PLA Update available". Fix at developer.apple.com. May need to fully quit + relaunch Xcode for the cached state to clear. This will likely surface again when Phase C creates a new App ID for the FoqosMacFilter extension.
- **SwiftData `[String]?` materialization quirk in upstream Foqos**: occasionally surfaces as `CoreData: Could not materialize Objective-C class named "Array"` warning. Doesn't always cause functional issues but is associated with the first-add-domain race we observed (where adding `instagram.com` initially produced an empty `domains` list). If Mac blocking shows stale or empty domains in production, this is the upstream bug to investigate.

---

## 12. Sandbox / tool constraints (for Claude sessions)

The Claude environment has filesystem write restrictions:
- **Reads** allowed anywhere
- **Writes** allowed only to `.` (cwd) and `$TMPDIR` (`/tmp/claude-501`)
- Cwd is now `/Users/emreonal/projects/FoqosUp` itself (since the foqosUp → FoqosUp migration), so **direct writes anywhere under the repo are allowed**.

**Workflow**: Claude edits files in place via the `Edit`/`Write` tools and the user reviews diffs before commit. The earlier "stage to `/tmp/claude-501/...` + bash install.sh" pattern (used during the foqosUp → FoqosUp migration when cwd was a deleted directory) is no longer needed for any work inside `~/projects/FoqosUp/`. Xcode GUI operations (target creation, capability adds in the Signing & Capabilities tab, provisioning regeneration) still require the user — Claude can't drive Xcode.

---

## 13. Conventions

- **Logging subsystem** for the iOS bridge: `com.usetessera.mybrick`. Use `os_log` / `Logger`. Filter in Console.app.
- **Logging subsystem** for the Mac app: same.
- **No emojis in code** unless the user asks. Match Foqos's existing style.
- **No comments in committed code** except where the *why* is non-obvious (per the user's CLAUDE.md preferences from the original planning doc, archived).
- **Test on device** — Simulator doesn't support NFC, Screen Time API, or NetworkExtension.
- **Apple Silicon Mac** required for the FoqosMac target (signing differs slightly from Intel; we don't worry about Intel).

---

## 14. Reference architectures (for code lifts)

- Apple's `SimpleFirewall` — minimal NEFilterDataProvider sample. WWDC 2019 session 714. Search "SimpleFirewall site:developer.apple.com".
- LuLu by Patrick Wardle — production NETransparentProxyProvider on macOS. https://github.com/objective-see/LuLu. Useful: entitlements plist, System Extension activation flow, App Group IPC pattern. NOT useful: hostname-from-flow logic (LuLu doesn't do SNI inspection — they accept the IP-only limitation for Chrome).
- For TLS ClientHello SNI parsing in Swift: ~50 LOC, well-documented. Multiple open-source TLS parsers to copy from. The TLS ClientHello structure is in RFC 8446 §4.1.2. SNI extension is RFC 6066 §3.

---

## 15. Build & test (when ready)

### iOS

```bash
cd ~/projects/FoqosUp/Foqos
open foqos.xcodeproj
# Connect iPhone via USB, Cmd+R
```

### Mac

```bash
cd ~/projects/FoqosUp/FoqosMac
open FoqosMac.xcodeproj
# Run on dev Mac (Cmd+R)
# First run prompts for System Extension approval
```

### Verifying the iCloud bridge

**Easiest path: use FoqosMac itself** (Phase B onwards). Run FoqosMac from Xcode (`⌘R`). The menu bar dropdown shows live state. Brick on iPhone → menu bar lock icon flips within ~1–2s.

**Alternate: Xcode debug console** (more diagnostic detail). With the Foqos iOS app or FoqosMac app running from Xcode and the debugger attached:
- Filter the Xcode debug area on `iCloudBridge` (iOS) or `ICloudObserver` (Mac)
- iOS side: NFC scan → `sessionStarted profile=… domains=…`
- Mac side: NFC scan → `External change reason=0 keys=[mybrick.isBlocked, …]`

⚠️ **Console.app is NOT a reliable verification path.** Console.app on macOS Tahoe filters out `os_log` Info messages from physical iPhones inconsistently even with "Include Info Messages" enabled. The iOS debugging story always works through Xcode's debug area when the debugger is attached. Once Xcode says "Finished running", the debug console stops capturing — must re-`⌘R`.

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
**Document version**: 2026-04-30 — Phase A and Phase B complete; Phase C (System Extension) is next.
