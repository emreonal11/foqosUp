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

## 6. macOS Mac app — planned architecture

### Targets

```
FoqosMac.xcodeproj/
├── FoqosMac/                  ← container app (SwiftUI MenuBarExtra)
│   ├── FoqosMacApp.swift      ← @main, MenuBarExtra
│   ├── ICloudObserver.swift   ← NSUbiquitousKeyValueStore listener
│   ├── ExtensionActivator.swift  ← OSSystemExtensionRequest flow
│   ├── EmergencyOverride.swift   ← PIN UI + Keychain storage
│   ├── AppGroupBridge.swift   ← writes state to App Group, posts Darwin notification
│   └── FoqosMac.entitlements
└── FoqosMacFilter/            ← System Extension
    ├── FilterDataProvider.swift   ← NEFilterDataProvider subclass
    ├── FilterControlProvider.swift ← NEFilterControlProvider stub
    ├── SNIParser.swift            ← TLS ClientHello SNI extraction
    ├── BlocklistMatcher.swift     ← exact + suffix matching
    └── FoqosMacFilter.entitlements
```

### Container app entitlements

- `com.apple.developer.ubiquity-kvstore-identifier` = `$(TeamIdentifierPrefix)com.usetessera.mybrick` (same as iOS)
- `com.apple.security.application-groups` = `[group.com.usetessera.mybrick]`
- `com.apple.developer.networking.networkextension` = `[content-filter-provider-systemextension]`
- `com.apple.developer.system-extension.install` = true

### Extension entitlements

- `com.apple.security.application-groups` = `[group.com.usetessera.mybrick]`
- `com.apple.developer.networking.networkextension` = `[content-filter-provider-systemextension]`

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
- `FoqosMacApp.swift` triggers a SourceKit lint warning "main attribute cannot be used in a module that contains top-level code" because `@main struct FoqosMacApp` shares the file with `BridgeState`, `ICloudObserver`, and `BridgeKey`. Compiler accepts it; the IDE indexer is just grumpy. Cleanup task for Phase C: split `BridgeState`/`ICloudObserver` into a separate file (requires adding to the Xcode target via `project.pbxproj`).

**Pending (Phase C — System Extension)**:
1. NEFilterDataProvider + NEFilterControlProvider stub
2. Extension activation via OSSystemExtensionRequest
3. First test: hardcoded block, verify in Chrome

**Pending (Phase D — Filter logic)**:
1. Hostname matching for Safari/Firefox path
2. SNI inspection for Chrome path (TLS ClientHello parser)
3. Real-world testing against blocklist domains

**Pending (Phase E — Polish)**:
1. SMAppService login-at-startup
2. Menu bar status icon
3. Emergency override (Keychain PIN)
4. Notarize for personal use

---

## 12. Sandbox / tool constraints (for Claude sessions)

The Claude environment has filesystem write restrictions:
- **Reads** allowed anywhere
- **Writes** allowed only to `.` (cwd) and `$TMPDIR` (`/tmp/claude-501`)
- The cwd `/Users/emreonal/projects/mybrick` was deleted after migration; **writes to `~/projects/FoqosUp/` are blocked**

**Workaround**: Claude writes new file contents to `/tmp/claude-501/...` and provides a copy script the user runs. Examples of this pattern: the migration script, the apply-overrides update.

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

After Phase A:
1. Build iOS to phone
2. Open Console.app on Mac (user's Mac, signed into same iCloud)
3. Filter: `subsystem == "com.usetessera.mybrick"`
4. On phone: scan NFC to start a session
5. Console should show `[ICloudStateBridge] sessionStarted` within ~20s of the brick
6. Verify keys via terminal: `defaults read com.apple.iCloud.UbiquitousKeyValueStore` (or use the Mac container app once it exists)

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
**Document version**: 2026-04-29 — Phase A in progress
