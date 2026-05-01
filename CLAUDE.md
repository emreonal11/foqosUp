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

**Done (Phase C0 — file split + LSUIElement)** (commit `7863e20`):
- ✅ Split `BridgeState`, `ICloudObserver`, `BridgeKey` from `FoqosMacApp.swift` into separate files. Cleared the SourceKit "main attribute / top-level code" warning.
- ✅ `INFOPLIST_KEY_LSUIElement = YES` set on FoqosMac container target — hides Dock icon, app is purely menu bar. Pulled forward from Phase E.
- ✅ Discovered `PBXFileSystemSynchronizedRootGroup` (`objectVersion = 77`, Xcode 26.x): files dropped into target's source dir auto-included; no pbxproj membership edit needed for new Swift files. See §6 "Synchronized file groups."

**Done (Phase C1 — System Extension target)** (commit `0dfaa45`):
- ✅ FoqosMacFilter target added via Xcode GUI (File → New → Target → macOS **System Extension** (NOT Application Extension) → Network Extension → Provider Type **"Filter Data"**).
- ✅ Bundle ID `com.usetessera.mybrick.FoqosMac.FoqosMacFilter` (child of container, required for sysextensions).
- ✅ Product type `com.apple.product-type.system-extension`. Embedded in container's `Contents/Library/SystemExtensions/`.
- ✅ Filter target also uses synchronized groups; `Info.plist` excluded via `PBXFileSystemSynchronizedBuildFileExceptionSet` (referenced by `INFOPLIST_FILE` build setting).
- ✅ Xcode-generated stubs: `FilterDataProvider.swift`, `main.swift` (calls `NEProvider.startSystemExtensionMode()`), `Info.plist`, `FoqosMacFilter.entitlements`.

**Done (Phase C2 — entitlements + signing)** (commits `80e9adf`, `54e8d13`):
- ✅ Container `FoqosMac.entitlements`: added `com.apple.developer.networking.networkextension` + `com.apple.developer.system-extension.install`.
- ✅ Filter `FoqosMacFilter.entitlements`: added the same NE entitlement, fixed App Group from placeholder to `group.com.usetessera.mybrick`, made `app-sandbox = true` explicit.
- ✅ **Critical: switched from `content-filter-provider-systemextension` → `content-filter-provider` (legacy)**. Apple Development provisioning profiles authorize ONLY the legacy value; the `-systemextension` suffix is gated to Developer ID signing (distribution path). Xcode's "+ Capability → Network Extensions → Content Filter" UI also writes the legacy value.
- ✅ Both targets build green with Apple Development cert + automatic signing.
- ✅ Filter Info.plist `NSSystemExtensionUsageDescription` set to user-facing string (shown in macOS approval prompt).

**Done (Phase C3 — ExtensionActivator)** (commit `26c2ad9`):
- ✅ `ExtensionActivator.swift` in container: drives `OSSystemExtensionRequest.activationRequest(...)` and configures `NEFilterManager`.
- ✅ Auto-trigger on first launch (`BridgeState.init()` calls `activateIfNeeded()`).
- ✅ Always submits activation request regardless of `NEFilterManager.isEnabled` state — handles the case where prefs say "enabled" but the running extension is stale (different cdhash, different Mach service name).
- ✅ Sets `cfg.filterDataProviderBundleIdentifier` explicitly.
- ✅ `FilterStatus` enum surfaced via `@Published` on `BridgeState`; ContentView shows inline status caption (color-coded).
- ✅ `OSSystemExtensionRequestDelegate` methods are `nonisolated` and dispatch to `@MainActor` via `Task { @MainActor in ... }`.

**Done (Phase C4 — hardcoded block proof of life)** (commits `03f696c`, `169d5e1`, `1689966`):
- ✅ `FilterDataProvider.startFilter`: applies `NEFilterSettings(rules: [], defaultAction: .filterData)` so all flows route through `handleNewFlow`.
- ✅ `handleNewFlow`: casts to `NEFilterSocketFlow`, uses **modern `remoteFlowEndpoint` API** (deprecated `remoteEndpoint` warned on Tahoe), branches on `.name` / `.ipv4` / `.ipv6` cases.
- ✅ **Critical fix**: `NEMachServiceName` in filter Info.plist must be prefixed with one of the App Groups in the entitlement. Was `$(TeamIdentifierPrefix)com.usetessera.mybrick.FoqosMac.FoqosMacFilter`, fixed to `group.com.usetessera.mybrick.FoqosMacFilter`. Sysextd's category-specific validator (NetworkExtensionErrorDomain Code=6) rejected the extension with this exact error.
- ✅ Verified: pipeline drops flows. `Replacing existing extension → stopFilter → startFilter → Filter settings applied → flow allow/DROP <hostname>` end-to-end via SNI test.
- ⚠️ **Critical learning**: on macOS Tahoe 26.3, **every flow surfaces as IP** (.ipv4 / .ipv6), even from Safari and NSURLSession-based clients. Kernel resolves DNS before flows reach the filter. The "hostname for Safari/Firefox/NSURLSession" claim in §3 is OUTDATED for macOS Tahoe; only direct `.name` flows that some legacy clients still surface fire that path. **All modern blocking has to go through `handleOutboundData` SNI inspection** — Phase D became the actual functional path, not a Chrome-only optimization.

**Done (Phase D — SNI inspection)** (commits `db68a5f`, `7ada398`):
- ✅ `FoqosMacFilter/SNIParser.swift`: standalone bounds-checked TLS ClientHello parser (~120 LOC). Public surface: `extractSNI(from: Data) -> String?`. Implements RFC 8446 §4.1.2 (TLS 1.3) + RFC 5246 §7.4.1.2 (TLS 1.2) + RFC 6066 §3 (SNI extension). Every read goes through a `Cursor` that returns nil on bounds violation — never crashes on untrusted bytes.
- ✅ `#if DEBUG SNIParserSanityCheck`: golden-vector test that runs once at every `startFilter` against a hand-built ClientHello with SNI=`example.com` + a truncated copy. Logs ✓/✗. Caught a regression-class bug pre-prod-style.
- ✅ `FilterDataProvider.handleNewFlow`: IP-only flows now return `.filterDataVerdict(peekOutboundBytes: 4096)` instead of allowing.
- ✅ `FilterDataProvider.handleOutboundData`: parses ClientHello, extracts SNI, decides allow/drop.
- ✅ **QUIC blackhole** (`7ada398`): all UDP/443 flows dropped at `handleNewFlow`. Browser HTTP/3 over QUIC carries TLS handshake in encrypted CRYPTO frames — SNI parser can't see anything. Drop forces TCP+TLS fallback (~50ms penalty) where SNI inspection works.
- ✅ Verified end-to-end via `curl -v --max-time 8 https://example.com`: returns `Recv failure: Socket is not connected` (curl exit 35, SSL handshake aborted by `.drop()`). `curl https://google.com` returns 301. `SNI DROP example.com` log lines fire on every fresh attempt.

**In progress (Phase C5 — drive blocklist from iCloud-mirrored App Group state)** (commits `d1d4c65`, `c95d9f5` — **BLOCKED, see Phase C5 BLOCKER section below**):
- ✅ Code written and committed:
  - `FoqosMac/FoqosMac/AppGroupBridge.swift`: `BlocklistSnapshot` Codable struct + singleton `AppGroupBridge.publish(...)`. Encodes JSON, writes to `UserDefaults(suiteName: "group.com.usetessera.mybrick")` with key `"com.usetessera.mybrick.blocklist.v1"`, posts Darwin notification `"group.com.usetessera.mybrick.state.changed"`. Dedups against last-published snapshot.
  - `BridgeState.refresh()`: now calls `AppGroupBridge.shared.publish(...)` after iCloud KV reads.
  - `FoqosMacFilter/BlocklistState.swift`: identical-schema `BlocklistSnapshot` + `@unchecked Sendable` singleton with NSLock-guarded snapshot. `shouldBlock(host:)` does the full suspended-active check + suffix match. `reloadFromAppGroup()` reads JSON from App Group UserDefaults.
  - `FilterDataProvider`: removed hardcoded `Set<String>(["example.com"])`. `startFilter` calls `BlocklistState.shared.reloadFromAppGroup()` + `setupDarwinObserver()`. Both `handleNewFlow` (.name path) and `handleOutboundData` (SNI path) call `BlocklistState.shared.shouldBlock(host:)`. Darwin observer uses `Unmanaged.passUnretained / fromOpaque` pattern.
- ⚠️ **Verification: PARTIALLY FAILS**. `scripts/c5-verify.sh` runs 6 assertions; 4 pass (T1, T2-google, T2, T4); 2 fail (T1-example, T5). The pattern is consistent: every test where we expect `example.com` to load via curl gets `curl: (35)` instead, while the SNI DROP log lines fire on `example.com`. Container's published state at startup is still in effect — the test injections aren't reaching the filter.

### Phase C5 BLOCKER (active investigation, hand off here)

**Problem**: `scripts/c5-verify.sh` injects synthetic snapshots via `defaults write group.com.usetessera.mybrick com.usetessera.mybrick.blocklist.v1 -data <hex>` then posts a Darwin notification. The filter receives the Darwin notification and calls `BlocklistState.reloadFromAppGroup()` — confirmed via logs (`Darwin: state.changed — reloading from App Group`). But every reload logs `No snapshot in App Group; using empty (fail-open).` even though `defaults read` from the shell shows the data is present.

**The smoking-gun discovery** (run `ls -la ~/Library/Preferences/group.com.usetessera.mybrick.plist ~/Library/Group\ Containers/group.com.usetessera.mybrick/Library/Preferences/group.com.usetessera.mybrick.plist`):

There are **two physical plist files**, with different content:
- `~/Library/Preferences/group.com.usetessera.mybrick.plist` (179 bytes) — written by **shell** `defaults write group.X` (non-sandboxed process)
- `~/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/group.com.usetessera.mybrick.plist` (209 bytes) — written by the **sandboxed container app** `UserDefaults(suiteName:)`

The CONTAINER successfully writes to #2 (verified via timestamps + content showing the iCloud-derived `instagram.com`). The shell test writes to #1. They're separate files; shell writes are invisible to sandboxed processes.

**But the deeper problem**: even when only the container is writing to file #2, the **filter (running as root)** still logs "No snapshot in App Group" on its first `reloadFromAppGroup` call at `startFilter`. The container's write to #2 happens *before* the filter's reload (verified by timestamp ordering: container "Published" at 03:07:26.141, filter init at 03:07:27.371, first reload at 03:07:27.377). The filter should see the container's bytes — but doesn't.

**Most likely root cause** (untested hypothesis): **macOS System Extensions run as root (UID 0). UserDefaults(suiteName:) with the App Group entitlement reads from a per-user App Group container path. The user's container path (`/Users/emreonal/Library/Group Containers/...`) is owned by user 501. The filter (root) may be reading from `/var/root/Library/Group Containers/...` or some other system-wide path — empty.** Container (running as user 501) writes to user 501's path, filter (root) reads its own root path — they never share.

**Diagnostic data**:

Filter PID seen in logs is owned by UID 0 (root), per the c4-redeploy.out earlier (`0   72231     1   0  1:13AM ?? ... /Library/SystemExtensions/.../com.usetessera.mybrick.FoqosMac.FoqosMacFilter`).

Container PID is owned by UID 501.

Apple's NetworkExtension samples (SimpleFirewall, etc.) reportedly use **NSXPCConnection** for container ↔ filter IPC, NOT App Group UserDefaults. Possible interpretation: App Group UserDefaults doesn't actually work for sysext-container IPC due to this UID split, and Apple's samples avoid it by using XPC. But this needs verification; it's a hypothesis.

**Investigation paths for the next session** (in order of effort):
1. **Confirm the UID split hypothesis** by checking what files the filter process actually has open. Run as user with sudo: `sudo lsof -p $(pgrep -f FoqosMacFilter)` and look for any `group.com.usetessera*` or root-side App Group container paths. Or `sudo find /var/root -name "group.com.usetessera*"`.
2. **If different paths**: switch from App Group UserDefaults → NSXPCConnection. The Mach service name (`group.com.usetessera.mybrick.FoqosMacFilter`) is already in the filter's Info.plist — it's the same name the container's `OSSystemExtensionRequest` flow registers. Filter implements `NSXPCListener` with that mach service name; container connects via `NSXPCConnection(machServiceName:)`. State updates become method calls. Reference: Apple's SimpleFirewall sample.
3. **If same paths but cache issue**: try `defaults.synchronize()` more aggressively, or use `CFPreferencesAppSynchronize` directly. Less likely root cause given the UID split fits the symptom better.
4. **If UID split confirmed but XPC is too heavy**: file-based IPC at a known path both root and user 501 can read/write. E.g., `/Library/Application Support/MyBrick/state.json` (writable by admin group, readable by everyone). Container writes, filter reads + watches with `DispatchSource.makeFileSystemObjectSource`. Lower fidelity than XPC but simpler.

**Recommended path**: option 2 (NSXPCConnection). Apple's canonical pattern, well-documented. ~150 LOC additional but solves the UID split definitively. This is the correct senior-SWE answer if the hypothesis is confirmed.

**The actual end-to-end test the user wants to see** (independent of how IPC is solved):
1. Brick iPhone with profile containing `instagram.com`
2. Wait ~2s (iCloud sync + container publish)
3. Open Chrome (incognito to avoid cache)
4. Navigate to https://instagram.com
5. Should fail with TCP-level error
6. Unbrick → instagram.com loads again

**Pending (Phase C6 — real-iPhone end-to-end)**: just the test above, blocked on C5.

**Pending (Phase D — Chrome SNI inspection)**: ✓ DONE (see above).

**Pending (Phase E — Polish)**:
1. SMAppService login-at-startup (`SMAppService.mainApp.register()`)
2. Custom menu bar icon (currently uses SF Symbol `lock.fill` / `lock.open`)
3. ✓ `LSUIElement = YES` already done in C0
4. Emergency override (4-digit PIN in Keychain, local-only, doesn't write to iCloud — see §6)
5. Notarize for personal use (avoids Gatekeeper warnings on rebuild). Also: Developer ID signing required for `-systemextension` entitlement variant.
6. Custom AppIcon (currently default Xcode template)

**Pending (Phase E — Polish)**:
1. SMAppService login-at-startup (`SMAppService.mainApp.register()`)
2. Custom menu bar icon (currently uses SF Symbol `lock.fill` / `lock.open`)
3. `LSUIElement = true` in Info.plist to hide Dock icon (currently shows in both Dock + menu bar)
4. Emergency override (4-digit PIN in Keychain, local-only, doesn't write to iCloud — see §6)
5. Notarize for personal use (avoids Gatekeeper warnings on rebuild)
6. Custom AppIcon (currently default Xcode template)

### Cross-cutting learnings from Phase C, D, C5 (preserve for future sessions)

- **macOS Tahoe 26.3 surfaces ALL flows as IP, not hostname.** The CLAUDE.md §3 "hostname for Safari/Firefox/NSURLSession" line is outdated. Even Safari traffic shows `.ipv4`/`.ipv6` cases on `NEFilterSocketFlow.remoteFlowEndpoint`, never `.name`. Kernel resolves DNS before flows reach the filter. Hostname-string matching from `handleNewFlow` essentially never fires. **All blocking goes through `handleOutboundData` SNI inspection.** Phase D became the actual functional path, not a Chrome-only optimization.
- **Apple Development cert profiles authorize `content-filter-provider` (legacy), NOT `content-filter-provider-systemextension`.** The `-systemextension` suffix is gated to Developer ID signing. Xcode's "+ Capability → Network Extensions → Content Filter" UI also writes the legacy value. To ship eventually we'd need Developer ID. For dev: use legacy.
- **`NEMachServiceName` MUST be prefixed with one of the App Groups** in `com.apple.security.application-groups`. Sysextd's category-specific validator returns `NetworkExtensionErrorDomain Code=6` if not. Our App Group is `group.com.usetessera.mybrick` (literal `group.` prefix, not team-prefixed) so the Mach service is `group.com.usetessera.mybrick.FoqosMacFilter`. Apple's SimpleFirewall sample team-prefixes BOTH (App Group is `$(TeamIdentifierPrefix)<bundle-id>`); we can't follow that pattern because iOS Foqos uses the `group.` form.
- **Darwin notification names from sandboxed processes MUST be prefixed with the App Group.** Was `com.usetessera.mybrick.state.changed`, fixed to `group.com.usetessera.mybrick.state.changed`. Sandbox silently drops mismatched notifications.
- **Same-version replace doesn't always trigger `actionForReplacingExtension`.** OS may consider `(bundleID, CFBundleVersion)` already-installed and skip the replace path even if the new binary's cdhash differs. Solution: use `date +%s` (epoch seconds) as `CURRENT_PROJECT_VERSION` for every dev build — guaranteed unique. `scripts/dev-iterate.sh` and `scripts/c5-verify.sh` do this with bump-then-revert so working tree stays clean.
- **`NEFilterDataVerdict.drop()` on a TCP flow PAUSES the flow indefinitely** rather than hard-closing it. Per Apple DTS. The TLS handshake can't proceed; client eventually times out. Browsers may serve cached pages while the connection stalls — this is why early "example.com still loads in Chrome" was misleading. Use `curl -v --max-time 8` for definitive verification (no cache, single connection per attempt).
- **`/Applications` is required for sysext install on macOS Tahoe 26**, even with `systemextensionsctl developer on`. The `developer on` mode relaxes signing checks but NOT the location requirement. All dev iteration must deploy to `/Applications/FoqosMac.app` before `OSSystemExtensionRequest` will succeed.
- **`systemextensionsctl developer on` requires SIP off.** User has SIP on, so this command failed. We worked around it by deploying to /Applications directly (which works without dev-mode). Uninstalling old extension versions also requires SIP off — instead they get marked "terminated waiting to uninstall on reboot" and pile up in `systemextensionsctl list` until reboot.
- **`PBXFileSystemSynchronizedRootGroup` (Xcode 26.x default, `objectVersion = 77`)**: files in a target's source dir auto-included in the build. New `.swift` files don't need pbxproj membership entries. `Info.plist` is excluded via `PBXFileSystemSynchronizedBuildFileExceptionSet` because it's referenced by `INFOPLIST_FILE` build setting instead of being a source.
- **NEFilterDataProvider runs as root, container runs as user 501** — App Group UserDefaults storage paths are per-user. Container writes to `/Users/emreonal/Library/Group Containers/...`; filter (as root) likely reads from `/var/root/Library/Group Containers/...` (different file). This is the active C5 blocker. Apple's NetworkExtension samples reportedly use NSXPCConnection for container↔filter IPC, not App Group UserDefaults. See Phase C5 BLOCKER section above for full diagnostic.
- **Sandbox blocks `xcodebuild` + `log show` + `/Applications` writes from Claude's environment.** Build/deploy/test must run from the user's terminal. Claude can edit source files but can't drive the dev cycle without user-side scripts. `scripts/c5-verify.sh` is the canonical "I edit code → user runs script → I read output" loop.
- **Logger.info messages are filtered out of `log show` by default**. Need `--info --debug` flags to see them. Initial diagnostic runs missed all FilterDataProvider activity because of this — false impression that "filter isn't running" when it just wasn't logging at the visible level. Always include `--info --debug` in log show predicates for our subsystem.
- **`defaults` command name conflict**: don't name a bash function `log` — it shadows the macOS `log` CLI tool. Use `say` or similar for log helpers.

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

---

## 16. Dev workflow scripts (Mac)

All under `scripts/`. Run from the user's terminal (Claude's sandbox blocks xcodebuild, log show, /Applications writes).

### `scripts/dev-iterate.sh`
One-shot dev iteration loop. Bumps `CURRENT_PROJECT_VERSION`, builds via xcodebuild, copies fresh `.app` to `/Applications`, kills old processes, launches, then `exec /usr/bin/log stream` to tail extension logs (Ctrl-C to exit). Reverts pbxproj at end so working tree stays clean.

Use when: making code changes during active dev, want to see live logs while testing.

### `scripts/c5-verify.sh`
End-to-end verification with bump→build→deploy→inject-synthetic-state→curl-test→capture-logs→verdict. Bumps version to `date +%s` (always unique, forces OS replace). Tests 6 assertions:
1. Empty App Group → example.com works
2. `{isBlocked:true, domains:[example.com]}` → example.com blocked
3. `{isBlocked:true, isBreakActive:true, ...}` → example.com works (break suspends)
4. Subdomain match: `www.example.com` blocked when domains contains `example.com`
5. `{isBlocked:false, ...}` → example.com works
6. Implicit: `google.com` works in all states

Output: `scripts/c5-verify.out` with a clear PASS/FAIL verdict and full diagnostic logs (FilterDataProvider, BlocklistState, ExtensionActivator, AppGroupBridge categories).

Currently 4/6 passing — see Phase C5 BLOCKER. The 2 failures are the synthetic injection mechanism (defaults write to wrong file) — the real-iPhone path is unblocked once C5 IPC is fixed.

### `scripts/c4-verify.sh`, `scripts/c4-test.sh`
Earlier verification scripts kept as historical reference for the C4/D pipeline-only test. Superseded by `c5-verify.sh` for ongoing dev verification but useful diagnostic tools if filter pipeline ever regresses.

### `scripts/c4-diagnose.sh`
Diagnostic snapshot: systemextensionsctl list + NEFilterManager prefs dump + sysextd logs + neagent logs + FilterDataProvider logs since launch + process list. Useful when something's wrong and you want a one-shot data dump.

### `scripts/.c4-build.log`, `scripts/c4-*.out`, `scripts/c5-*.out`
Build/run output files. Gitignored via `scripts/*.out` rule. The `.c4-build.log` is xcodebuild's stdout from the verify scripts — read this if BUILD FAILED.

### Common pitfalls
- **Stale build**: c5-verify.sh checks build mtime vs source mtime; bails if build is older. If you edit code, the script will rebuild. If the script complains about staleness, the source-write hadn't completed (rare).
- **Root-owned `.out` files**: if you ever accidentally `sudo`-run a script, the output file becomes root-owned and subsequent non-sudo runs fail with `Permission denied`. Scripts handle this by `rm -f` + sudo fallback at start.
- **`/Applications/FoqosMac.app` permission**: occasionally needs sudo to remove (filesystem lock from running process). Scripts try non-sudo first, fall back to sudo.
- **System Extension version pile-up**: every iteration adds a `[terminated waiting to uninstall on reboot]` entry to `systemextensionsctl list`. Reboot to clean up; not blocking for dev.

---

## 17. Handoff prompt — paste this into the next session

```
Continuing the MyBrick / FoqosUp project at ~/projects/FoqosUp/.

STEP 1: read CLAUDE.md in full. It is the SSOT. Especially:
  - §1 (project intent — cooperative self-blocking; iPhone NFC bricks Mac too)
  - §11 "Where we are right now" — full execution state through Phase C5
  - §11 "Phase C5 BLOCKER" — the active investigation
  - §11 cross-cutting learnings sections — failure modes already discovered
  - §6 macOS Mac app architecture
  - §16 dev workflow scripts

STEP 2: read git log to confirm state.
  cd ~/projects/FoqosUp && git log --oneline -15

  Expected last commits (newest first):
    c95d9f5 C5 fix: App-Group-prefixed Darwin name + epoch version + diagnostics
    d1d4c65 C5: drive blocklist from iCloud-mirrored App Group state
    7ada398 D fix: QUIC blackhole — drop UDP/443 to force TCP+TLS fallback
    db68a5f D: SNI inspection — extract destination hostname from TLS ClientHello
    1689966 C4 verified: pipeline drops flows; hostname surfacing is Phase D
    169d5e1 C4 fix: NEMachServiceName must be prefixed with the App Group
    03f696c C4: hardcoded example.com block — proof of life
    26c2ad9 C3: ExtensionActivator + auto-activate on first launch
    54e8d13 C2 fix: switch to content-filter-provider (legacy) for dev signing
    80e9adf C2: configure entitlements for content-filter system extension
    0dfaa45 C1: add FoqosMacFilter System Extension target
    7863e20 C0: split FoqosMacApp.swift, hide Dock icon
    2750995 Doc fixes: sandbox policy + synchronized file groups

STEP 3: orient yourself on the C5 blocker.

WHAT WORKS (verified end-to-end):
  - iCloud bridge iOS↔Mac (Phase A+B): brick iPhone → Mac dropdown shows
    isBlocked=true, domains=[instagram.com], in 1-2s
  - System Extension install + activation (Phase C1-C4)
  - SNI parser + drop pipeline (Phase D): curl https://example.com fails with
    `curl: (35) Recv failure: Socket is not connected`, curl https://google.com
    succeeds. Verified via scripts/c4-verify.sh and earlier c5-verify.sh runs.
  - QUIC blackhole (UDP/443 drop) forces TCP+TLS fallback for Chrome/HTTP3.
  - App Group entitlement is correctly configured on both targets.
  - Container's AppGroupBridge.publish writes BlocklistSnapshot JSON to
    UserDefaults(suiteName: "group.com.usetessera.mybrick") successfully —
    confirmed by direct file inspection.
  - Filter receives Darwin notifications correctly when posted with
    App-Group-prefixed name "group.com.usetessera.mybrick.state.changed" —
    confirmed by "Darwin: state.changed — reloading from App Group" logs.
  - BlocklistState.reloadFromAppGroup() is called on every notification —
    confirmed by "No snapshot in App Group; using empty (fail-open)" logs.

WHAT'S BROKEN:
  Filter logs "No snapshot in App Group" on every reload, even after the
  container has written successfully and even after shell scripts inject
  synthetic snapshots. The two readers (sandboxed user-process container
  and root-process filter sysextension) appear to be reading DIFFERENT
  physical files for the same App Group identifier.

KEY DIAGNOSTIC EVIDENCE:
  Two physical plists exist:
    ~/Library/Preferences/group.com.usetessera.mybrick.plist
    ~/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/group.com.usetessera.mybrick.plist

  - Shell `defaults write group.X` writes to #1 (visible to non-sandboxed shells)
  - Container's UserDefaults(suiteName:) writes to #2 (sandboxed user-process)
  - Filter's UserDefaults(suiteName:) reads ?? — claims "no data" even
    when #2 contains data the container just wrote

  Most likely root cause: SystemExtension runs as root (UID 0) in
  /Library/SystemExtensions/.../FoqosMacFilter.systemextension. UserDefaults
  resolves App Group containers per-user. Filter (root) likely reads from
  /var/root/Library/Group Containers/ — empty. Container (user 501) writes
  to /Users/emreonal/Library/Group Containers/. Different files,
  cross-process IPC fails.

  Hypothesis to confirm:
    sudo lsof -p $(pgrep -f FoqosMacFilter) | grep -i "group.com.usetessera"
    sudo find /var/root -name "group.com.usetessera*" 2>/dev/null
    sudo find /Library -name "group.com.usetessera*" 2>/dev/null

STEP 4: pick a path forward. Strong recommendation: NSXPCConnection.

  Apple's NEFilterDataProvider samples (SimpleFirewall etc.) reportedly use
  NSXPCConnection between container and filter, not App Group UserDefaults.
  This is the canonical pattern that handles the UID split.

  Approximate plan for XPC pivot (~150 LOC):
    1. Filter implements NSXPCListener with the existing NEMachServiceName
       (already configured: "group.com.usetessera.mybrick.FoqosMacFilter").
       The Mach service is already registered for the filter — reuse it.
    2. Define a @objc protocol BlocklistService { func updateBlocklist(...) }
    3. Filter sets listener.delegate, accepts new connections, exports
       BlocklistService via NSXPCInterface.
    4. Container creates NSXPCConnection(machServiceName:options:.privileged
       or [] depending on Apple's recommendation for sysext IPC).
    5. AppGroupBridge.publish(...) becomes XPCBridge.publish(...) — calls
       the remote BlocklistService method.
    6. Remove App Group + Darwin notification approach. Keep the
       BlocklistSnapshot Codable struct as the wire format (sent as Data
       via NSXPCConnection).
    7. Update scripts/c5-verify.sh's synthetic injection to also use XPC
       (small Swift CLI helper) or just rely on real-iPhone test.

  Alternative path if XPC seems too heavy: file-based IPC at a known path
  both root and user 501 can access. E.g., /Library/Application Support/
  MyBrick/state.json (writable by admin group). Container writes, filter
  reads + watches with DispatchSource.makeFileSystemObjectSource. Lower
  fidelity than XPC but avoids the UID split.

  DO NOT skip the investigation step. Confirm the UID split hypothesis
  with lsof before committing to XPC. Senior-SWE approach: ground-truth
  the actual problem before pivoting architecture.

STEP 5: Re-verify your fix.

  Once IPC is working:
    1. Run scripts/c5-verify.sh — should now pass 6/6 if synthetic injection
       still works (depends on whether you keep the `defaults write` test or
       switch to XPC for synthetic state too).
    2. The real test: brick iPhone with profile containing example.com or
       instagram.com, run curl from Mac, expect block. Unbrick, expect curl
       to succeed.

OPERATIONAL RULES:
  - User has explicitly stated "rigor of senior Google SWE" is the bar.
    Apply: clean modular code, ground-truth research before pivoting,
    write tests that catch regressions, document trade-offs in commit
    messages.
  - Sandbox blocks: xcodebuild, log show, /Applications writes, sudo
    commands needing user approval. The user runs scripts; you read
    .out files. Don't ask the user to do things you can do yourself.
  - User gets frustrated by long verbose responses + speculation cycles.
    Be terse. Test before claiming. Trust git log.
  - Build/test loop: edit code → tell user "run scripts/c5-verify.sh"
    → read scripts/c5-verify.out → diagnose. Don't try to run xcodebuild
    yourself — sandbox blocks it.
  - SIP is ON, dev-mode is OFF. /Applications deployment + Apple Development
    cert is the dev path. systemextensionsctl uninstall doesn't work without
    SIP off; rely on actionForReplacingExtension's .replace verdict instead
    (works fine for cdhash-different builds).
  - User's iPhone is currently bricked with profile containing instagram.com
    (per last container publish in logs). This means real-iPhone test is
    available the moment IPC is fixed.

STEP 6: cleanup before declaring victory.
  - Once C5 is verified, commit a "doc fixes" commit updating CLAUDE.md
    §11 to mark Phase C5 ✅ DONE and remove the BLOCKER section.
  - Pause and report. Don't auto-proceed to Phase E.
```

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
**Document version**: 2026-05-01 — Phases A through D complete; Phase C5 (App Group → Darwin → filter IPC) BLOCKED on root-vs-user UID split. Phase C6 + Phase E pending.
