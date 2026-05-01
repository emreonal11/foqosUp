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

**Done (Phase C5 — drive blocklist from iCloud-mirrored state via XPC)** (initial App Group attempt: commits `d1d4c65`, `c95d9f5`; XPC pivot: this commit):
- ⚠️ First attempt used App Group `UserDefaults(suiteName:)` + Darwin notifications. **Failed at runtime** — container could never deliver state to the filter. See "Phase C5 root cause" below.
- ✅ Pivoted to NSXPCConnection (Apple's canonical sysext↔container IPC):
  - `FoqosMac{,Filter}/BlocklistService.swift`: `@objc(FoqosBlocklistService) protocol BlocklistService` declaration. Identical decl in both target source dirs (synchronized groups; no pbxproj exception needed). Single method: `updateBlocklist(_ data: Data, withReply reply: @escaping (Bool) -> Void)`. Wire format: JSON-encoded `BlocklistSnapshot`.
  - `FoqosMacFilter/IPCService.swift`: `NSXPCListener(machServiceName: "group.com.usetessera.mybrick.FoqosMacFilter")` (reuses the existing NEMachServiceName from Info.plist — NetworkExtension's internal sysextd↔filter channel is kernel-private, so app-level XPC on the same Mach name doesn't collide). Accepts incoming connections, decodes the JSON snapshot, swaps it into `BlocklistState` atomically.
  - `FoqosMac/IPCClient.swift`: persistent `NSXPCConnection` to the same Mach name. Invalidation/interruption handlers null the cached connection so the next `publish(...)` recreates it. Producer-side dedup against `lastPublished` skips no-op iCloud chatter.
  - `FoqosMacFilter/BlocklistState.swift`: now a pure in-memory cache. `update(_:)` is the only mutator (called by IPCService); `shouldBlock(host:)` reads under NSLock. No I/O.
  - `FoqosMacFilter/FilterDataProvider.startFilter`: `IPCService.shared.startListener()` instead of the old App-Group-reload + Darwin-observer dance. `stopFilter` no longer needs cleanup.
  - `FoqosMac/ExtensionActivator.saveToPreferences` success callback: forces `IPCClient.shared.resetDedup()` + `state?.refresh()` so the first publish at app launch (which raced extension activation and likely hit a dead XPC connection) gets retried as soon as the listener is up.
- ✅ Removed: `FoqosMac/AppGroupBridge.swift`, `BlocklistState.reloadFromAppGroup()`, the `setupDarwinObserver`/`removeDarwinObserver` methods + the `Unmanaged.passUnretained` dance, `AppGroupConstants` enums on both sides, all `defaults.synchronize()` calls.
- ✅ Kept: `BlocklistSnapshot` Codable (still the wire format, just over XPC instead of UserDefaults), `BlocklistState` class with NSLock-guarded snapshot + `shouldBlock(host:)` matching, the `com.apple.security.application-groups` entitlement (still required to validate `NEMachServiceName`).
- ✅ `scripts/c5-verify.sh` rewritten: synthetic shell injection removed (it could never reach a root sysext anyway). Now asserts XPC handshake (filter logs `XPC listener started`, `XPC client connected`, `Snapshot received`; container logs `Published:`) within a few seconds of launch, plus an optional real-iPhone block test gated on `TEST_BLOCKED_DOMAIN` env var.

### Phase C5 root cause — verbatim diagnostic evidence

The original App Group + Darwin design failed because **NEFilterDataProvider system extensions run as root (UID 0) under their own per-root sandbox container, so `UserDefaults(suiteName:)` resolves to a different physical plist than the user-level container app's writes ever touch.** Apple DTS has documented this on their Developer Forums:

> *"App groups aren't as useful in a sysex as they are in an appex because your sysex runs as root, and thus can't share a group container with its containing app."* — Quinn "The Eskimo!", thread 763433

> *"The problem with your setup is that your two programs are running as different users. The sysex runs as root and the container app runs as the logged in user. This will result in two different `container` paths… If I were in your situation I'd probably just switch to using XPC."* — Quinn "The Eskimo!", thread 133543

Confirmed verbatim on this machine via `scripts/c5-lsof-check.sh`:

```
Filter PID: 83030  UID 0 (root)
  cwd → /private/var/root/Library/Containers/<filter-bundle-id>/Data
Container PID: 82983  UID 501 (emreonal)
  cwd → /Users/emreonal/Library/Containers/<container-bundle-id>/Data

/var/root/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/
  → empty (no plist)
/Users/emreonal/Library/Group Containers/group.com.usetessera.mybrick/Library/Preferences/
  → group.com.usetessera.mybrick.plist (209 bytes, container's published snapshot)

sudo defaults read group.com.usetessera.mybrick com.usetessera.mybrick.blocklist.v1
  → "The domain/default pair … does not exist"
```

This is the canonical sysext UID split: even when the container correctly writes to its user-side App Group plist, the filter (root) reads from `/var/root/...` and sees nothing. Apple's `SimpleFirewall` sample uses NSXPCConnection over the filter's NEMachServiceName for exactly this reason.

**Done (Phase C6 — real-iPhone end-to-end)** (verified by `scripts/c5-verify.sh` with `TEST_BLOCKED_DOMAIN=instagram.com`, run `2026-05-01 03:59`):
- ✅ iPhone bricked with profile containing `instagram.com` → iCloud sync (~1–2s) → container's `BridgeState.refresh()` → `IPCClient.publish` → filter's `IPCService.updateBlocklist` → `BlocklistState.update`. Confirmed via paired log lines (`Snapshot received: blocked=true … domains=1` / `Updated: blocked=true … domains=1`).
- ✅ `curl -m 6 https://instagram.com` → `000` (TCP-level connection failure from `.drop()` verdict). Filter log: `SNI DROP instagram.com`.
- ✅ `curl -m 6 https://www.apple.com` → `200` (filter is not blackholing — verifies allow path on the same run).
- ✅ QUIC blackhole still firing (12+ `flow DROP udp/443` log lines for instagram's HTTP/3 attempts before browser fell back to TCP+TLS).
- ✅ `c5-verify.sh` reports **7/7 passed** for the full pipeline assertion set.

**Pending (Phase D — Chrome SNI inspection)**: ✓ DONE (see above).

**Phase E — Polish** (mixed status):
1. ✅ SMAppService login-at-startup — `FoqosMac/LoginItem.swift`. Idempotent `SMAppService.mainApp.register()` from `FoqosMacApp.init`. Respects user disabling in System Settings (early-out on `.requiresApproval`).
2. ✅ Custom AppIcon — Foqos's iOS marketing icon resized to all 10 macOS slots via `scripts/build-app-icons.sh` (sips). Generated PNGs committed to `FoqosMac/FoqosMac/Assets.xcassets/AppIcon.appiconset/`. Re-run the script after pulling fresh upstream Foqos assets.
3. ✅ Menu bar icon — kept SF Symbols for theme-awareness + macOS convention. Three-state: `lock.fill` (blocked), `lock.open` (not blocking), `lock.slash` (emergency override active).
4. ✅ `LSUIElement = YES` already done in C0.
5. ✅ Emergency override (4-digit PIN in Keychain) — `FoqosMac/EmergencyOverride.swift`. Stored under service `com.usetessera.mybrick.emergency`, `kSecAttrAccessibleWhenUnlocked`. Constant-time PIN compare. UI integrated into ContentView mode state machine (`.main` ↔ `.settingPIN` ↔ `.enteringPIN`). Engaging override forces `effectiveBlocked = false` in `BridgeState.publishEffectiveState()`; auto-lifts on the next material iCloud transition (any of `isBlocked`/break/pause/`domains`/`activeProfileId` changes vs. the snapshot taken at engage time). Local-only — never written to iCloud per §6.
6. ✅ ContentView UX overhaul — single-line top status combines block/break/pause/override; dropped `isBlocked`/`isBreakActive`/`isPauseActive`/`Profile` rows; domain count line replaces the (truncated) domain list; removed `Force sync` (kept `Quit`); `Synced X:XX` footer.
7. ⏳ **Phase F: Distribution** — TestFlight for iPhone (Foqos fork) + Developer ID + notarize for Mac. Friend doesn't need their own paid Dev account; user uploads iPhone build to App Store Connect → invites by email; user notarizes Mac .app and ships .dmg. Per §6's switch-when-distributing note: must move Mac filter entitlement from `content-filter-provider` (legacy / Apple Development cert) to `content-filter-provider-systemextension` (Developer ID). Recipe + docs to land in §18.

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
- **NEFilterDataProvider sysext runs as root (UID 0); container runs as the logged-in user.** Their `UserDefaults(suiteName:)` App Group paths are physically disjoint — the filter resolves to `/var/root/Library/Group Containers/...` while the container resolves to `/Users/<u>/Library/Group Containers/...`. **App Group UserDefaults / Darwin notifications cannot be used for sysext↔container IPC.** Apple DTS (Quinn the Eskimo, threads 133543 + 763433) explicitly recommends NSXPCConnection over the filter's NEMachServiceName instead; this is what `SimpleFirewall` does. We hit this wall in Phase C5 first-attempt, then pivoted to XPC. See "Phase C5 root cause" above for the verbatim lsof + DTS evidence.
- **`NSXPCListener.machServiceName` can reuse the filter's `NEMachServiceName`.** NetworkExtension's internal sysextd↔filter channel is kernel-private and disjoint from app-level XPC, so registering a user-facing NSXPCListener with the same Mach name doesn't collide. SimpleFirewall does exactly this. One Mach name → one NSXPCListener; do not register a second.
- **At app launch the first XPC publish races extension activation.** `BridgeState.init()` calls `refresh()` (which publishes) before `OSSystemExtensionRequest`'s callback chain finishes — so the filter listener may not be up yet and the publish silently fails. Fix: in `ExtensionActivator.saveToPreferences` success, call `IPCClient.shared.resetDedup()` + `state?.refresh()` to force a republish. Also: invalidation/interruption handlers null the cached `NSXPCConnection` and clear `lastPublished`, so subsequent failures self-heal on the next iCloud refresh.
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

Currently 7/7 passing (post-XPC pivot, with `TEST_BLOCKED_DOMAIN=instagram.com` set and the iPhone bricked).

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

STEP 1: read CLAUDE.md in full. SSOT. Most important sections:
  - §1 (project intent — cooperative self-blocking; iPhone NFC bricks Mac too)
  - §11 "Where we are right now" — execution state through Phase C5 (XPC)
  - §11 "Phase C5 root cause" — the UID-split diagnostic + DTS quotes
  - §11 cross-cutting learnings — failure modes already discovered
  - §6 macOS Mac app architecture
  - §16 dev workflow scripts

STEP 2: confirm state via git log.
  cd ~/projects/FoqosUp && git log --oneline -15

  Most recent commit should be the C5 XPC pivot. Earlier commits (Phase D,
  C4, C3, C2, C1, C0, Phase B, Phase A) are documented in §11.

STEP 3: where things stand.

WHAT WORKS (verified end-to-end through Phase D, C5 verification next):
  - iCloud bridge iOS↔Mac (Phase A+B): brick iPhone → Mac dropdown shows
    isBlocked=true, domains=[instagram.com], in 1-2s.
  - System Extension install + activation (Phase C1-C4).
  - SNI parser + drop pipeline (Phase D): hostname-based blocking via TLS
    ClientHello inspection from handleOutboundData. QUIC blackhole forces
    TCP+TLS fallback for HTTP/3 clients.
  - Container ↔ filter IPC via NSXPCConnection (Phase C5): container's
    BridgeState.refresh() pushes JSON-encoded BlocklistSnapshot through
    IPCClient → filter's IPCService → BlocklistState.update(). Replaces the
    earlier App Group UserDefaults + Darwin design which was unrecoverable
    due to the sysext UID split (filter runs as root, sees /var/root/...;
    container runs as user, writes to /Users/.../). DTS-confirmed; lsof
    evidence in commit body.

WHAT'S NEXT (Phase E — polish, see §11):
  - SMAppService login-at-startup
  - Custom menu bar icon
  - Emergency override (Keychain PIN)
  - Notarize for personal use
  - Custom AppIcon

OPERATIONAL RULES:
  - Senior-SWE rigor bar: clean modular code, ground-truth research before
    pivoting, document trade-offs in commit messages, verbatim diagnostic
    evidence in commit bodies (the C5 commit shows the pattern).
  - Sandbox blocks xcodebuild, log show, /Applications writes, sudo from
    Claude's environment. User runs scripts; Claude reads .out files.
    Don't ask the user to do things Claude can do itself (file edits).
  - Be terse. Test before claiming. Trust git log.
  - SIP is ON, dev-mode is OFF. /Applications deployment + Apple
    Development cert is the dev path. .replace verdict in
    actionForReplacingExtension handles cdhash-different rebuilds; old
    extension versions pile up as "terminated waiting to uninstall on
    reboot" until reboot.
  - When in doubt about libraries / Apple APIs, prefer context7 or
    Apple Developer Forums (Quinn the Eskimo's threads are gold) over
    web search.
```

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
**Document version**: 2026-05-01 — Phases A through D, C5, C6 all complete. C5 pivoted from App Group UserDefaults → NSXPCConnection after confirming the sysext UID-split; C6 verified by `scripts/c5-verify.sh` 7/7 with real iPhone state. Phase E (polish) pending.
