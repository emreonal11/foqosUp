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
  → iCloud syncs to Mac (~1–2 s typical, occasionally up to 20 s)
  → FoqosMac container app's ICloudObserver fires
  → BridgeState.refresh() reads the iCloud snapshot
  → IPCClient.publish(...) sends JSON-encoded BlocklistSnapshot over
    NSXPCConnection to the filter sysext
  → FoqosMacFilter's IPCService receives → BlocklistState.update(...)
  → BlocklistState alias-expands the user's profile domains (e.g.
    youtube.com → {youtube.com, googlevideo.com, ytimg.com, youtu.be,
    youtube-nocookie.com}) and caches the effective set
  → For each new TCP flow, FilterDataProvider.handleNewFlow peeks 4 KB
    outbound; handleOutboundData extracts SNI and either drops, allows,
    or keeps the flow under continuing inspection (peekBytes=Int.max)
  → On state transitions (break end, rebrick, blocklist mutation), the
    next outbound chunk on a watched flow triggers a retroactive drop —
    existing TCP connections to newly-blocked domains die without
    requiring browser tab close+reopen
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

### The hostname problem (Tahoe-wide, not Chrome-specific)

Original assumption: `NEFilterDataProvider.flow.remoteEndpoint.hostname` returns hostnames for Safari/Firefox/NSURLSession and IPs only for Chrome. **This was wrong on macOS Tahoe 26.3.** Verified empirically (Phase D): every TCP flow surfaces as `.ipv4` or `.ipv6`, never `.name`, regardless of client. The kernel resolves DNS before flows reach the filter. The `.name` case in `handleNewFlow` essentially never fires.

**Solution: SNI inspection from `handleOutboundData`.** When `handleNewFlow` sees an IP-only flow, return `.filterDataVerdict(peekOutboundBytes: 4096)`. The system then peeks the first 4 KB of outbound data and delivers them to `handleOutboundData`. We parse the TLS ClientHello to extract the SNI extension (RFC 6066 §3) and match against the alias-expanded blocklist. SNI is plaintext until ECH widely deploys; major distractor sites (Instagram, YouTube, X, Reddit, TikTok) had ~zero ECH adoption as of 2026.

QUIC complication: HTTP/3 carries the TLS handshake inside encrypted CRYPTO frames, so SNI inspection from outbound data doesn't work. Rather than parse QUIC, we drop **all UDP/443 flows** at `handleNewFlow` (the "QUIC blackhole"). Browsers fall back to TCP+TLS automatically — slight latency hit, full SNI visibility.

### Container ↔ Extension IPC: NSXPCConnection

The intuitive design — App Group `UserDefaults(suiteName:)` plus a Darwin notification — **does not work** for sysext↔container IPC on macOS. NEFilterDataProvider sysexts run as **root** under their own per-root sandbox container; the container app runs as the logged-in user. `UserDefaults(suiteName:)` resolves to physically separate plists under `/var/root/Library/Group Containers/...` vs `/Users/<u>/Library/Group Containers/...`. Each side reads/writes its own file; they never see each other's bytes. Verified empirically in Phase C5 with `scripts/c5-lsof-check.sh`. Apple DTS (Quinn the Eskimo, threads 133543 + 763433) explicitly confirms this and recommends NSXPCConnection.

What's actually used:
- Filter sysext (`IPCService.swift`): `NSXPCListener` bound to the filter's `NEMachServiceName` from Info.plist (`group.com.usetessera.mybrick.FoqosMacFilter`). NetworkExtension's internal sysextd↔filter channel is kernel-private and disjoint from app-level XPC, so the same Mach name doesn't collide.
- Container app (`IPCClient.swift`): persistent `NSXPCConnection` to that Mach service. Retry-with-backoff on the first publish (handles the dev-iteration race where the container connects to a dying old extension during sysext replacement).
- Wire format: JSON-encoded `BlocklistSnapshot` (the same Codable struct on both sides). Sent as a single `Data` argument in `updateBlocklist(_:withReply:)`.
- Reference: Apple's `SimpleFirewall` sample uses this exact pattern.

The App Group entitlement is **still required** — `NEMachServiceName` must be prefixed with one of the App Groups in `com.apple.security.application-groups` (sysextd's category-specific validator rejects mismatches with `NetworkExtensionErrorDomain Code=6`). We just no longer use the App Group for actual data sharing.

### Filter behavior on state transitions: watch every TLS flow

`NEFilterDataProvider` provides no API to retroactively drop a flow once `.allow()` has been returned. Verified via Apple's headers and DTS (forum thread 735504: *"once I return an allow/deny verdict for the flow … do I no longer see that flow's traffic in my content filter? — Correct."*). `applySettings`, `handleRulesChanged`, `notifyRulesChanged`, `applyNewFilterRules`, `resumeFlow` — all only affect new or paused flows, never `.allow()`d ones.

Consequence: if we `.allow()` a flow during normal browsing and the user later starts a focus session, the existing TCP connection (and any HTTP/2-multiplexed requests on it) bypass the filter forever. Browsers like Chrome aggressively reuse persistent connections for new tabs, so "I just bricked but YouTube keeps working" is the default experience without intervention.

**Fix**: never return `.allow()` from `handleOutboundData` for TLS flows after SNI extraction. Instead, return `NEFilterDataVerdict(passBytes: readBytes.count, peekBytes: Int.max)`. The system delivers in natural-sized chunks (typically per TCP segment, ~1-1.5 KB) rather than buffering up to a fixed threshold. Each subsequent chunk re-checks `BlocklistState.shouldBlock(host: cachedSNI)` against current state; transitions to "should now block" produce an immediate `.drop()` on the next byte of outbound activity. Idle flows fire zero callbacks (the system only invokes us when bytes actually move) — cost scales with throughput, not with elapsed time.

Per-flow SNI is cached in `watchedSNI: [UUID: String]` (NEFilterFlow's UUID is per-flow stable). Lifetime is "TLS flows seen since filter started" because the kernel doesn't notify on flow end. Bounded by total file descriptors; ~5-10 K entries × 40 bytes/entry = ~400 KB on a heavy 24-hour day. Negligible. Diagnostic milestone log (1 K / 5 K / 10 K / 50 K / 100 K) surfaces pathological growth in `log show`.

Why `Int.max` and not a fixed value: HTTP/2 control traffic produces small bursts (~1 KB headers per request). With `peekBytes = 64 KB`, dozens of clicks worth of activity could accumulate before the kernel flushes the buffer to us — state-change reaction was effectively never. `Int.max` makes Apple's framework deliver per-TCP-segment, so user-perceived reaction is bounded by user activity.

Cost on M2 Air: 0% idle, ~0.05% on a 5 Mbps stream, ~0.25% on 25 Mbps 4K, ~1% on 10 parallel heavy streams. Below the noise floor of any OS-exposed instrument.

### Alias expansion: profile-level intent → comprehensive domain coverage

A blocklist entry of `youtube.com` only suffix-matches `*.youtube.com`. It does NOT match `googlevideo.com` (where YouTube actually streams its videos), `ytimg.com` (thumbnails), `youtu.be` (short links), or `youtube-nocookie.com` (embeds). With only `youtube.com` blocked, YouTube tabs and Shorts kept playing video chunks via googlevideo.com — the page HTML was already in DOM and SPA navigation didn't trigger new www.youtube.com requests.

The fix lives in `BlocklistState.domainAliases` — a static map from "high-level service domain" to "all the SLDs that service depends on." When `BlocklistState.update(_:)` swaps in a new snapshot, we expand the user's profile entries through this map and cache the result. `shouldBlock` then suffix-matches against the expanded set.

Current aliases:
- `youtube.com` → `{youtube.com, googlevideo.com, ytimg.com, youtu.be, youtube-nocookie.com}`
- `instagram.com` → `{instagram.com, cdninstagram.com}`

Conservative inclusion: a domain joins an alias only if it's exclusively (or near-exclusively) used by the named service. Deliberately excluded:
- `ggpht.com` (used by Gmail avatars + Google Photos profile pics — over-blocks).
- `googleapis.com` (every Google service — over-blocks).
- `fbcdn.net` (shared across Instagram + Facebook + Messenger + WhatsApp — user can opt in by adding to their iOS profile manually if they want broader Meta coverage).

Keeps the iOS profile under Foqos's 50-entry limit and preserves the user's "block YouTube" mental model. Asymmetry with iOS Safari (which doesn't see this map) is documented but benign — iOS Foqos primarily blocks at the app layer via ManagedSettings / ApplicationToken; domains are mostly a Mac-side concern.

To extend: add a new mapping to `BlocklistState.domainAliases` and ship. No iOS-profile rebuild needed; the Mac filter alone owns the table.

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

The filter's `BlocklistState.shouldBlock(host:)` runs against the alias-expanded effective domain set (see §3 "Alias expansion"):

```swift
func shouldBlock(host: String) -> Bool {
    guard snap.isBlocked, !snap.isBreakActive, !snap.isPauseActive else { return false }
    let h = host.lowercased()
    for entry in effectiveDomains where !entry.isEmpty {
        if h == entry || h.hasSuffix(".\(entry)") { return true }
    }
    return false
}
```

`effectiveDomains` is a `Set<String>` recomputed once per state update by expanding the user's profile entries through `BlocklistState.domainAliases`. Suffix match means `youtube.com` covers `m.youtube.com`, `studio.youtube.com`, etc. — and via the alias, also `*.googlevideo.com`, `*.ytimg.com`, `youtu.be`, `*.youtube-nocookie.com`.

Called from two places:
- `FilterDataProvider.handleNewFlow` for the rare `.name` flow path (almost never fires on Tahoe — see §3 "hostname problem").
- `FilterDataProvider.handleOutboundData` for the SNI path, which is the actual blocking mechanism. Called once at first inspection and on every subsequent chunk of any watched flow (see §3 "Filter behavior on state transitions").

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

### Targets (current layout, post-Phase E)

```
FoqosMac.xcodeproj/
├── FoqosMac/                                ← container app (SwiftUI MenuBarExtra, LSUIElement=YES)
│   ├── FoqosMacApp.swift                    ← @main; calls LoginItem.ensureRegistered() in init
│   ├── ContentView.swift                    ← dropdown UI (mode state machine: .main / .settingPIN / .enteringPIN)
│   ├── BridgeState.swift                    ← @MainActor ObservableObject; reads iCloud, owns emergency-override logic
│   ├── BridgeKey.swift                      ← iCloud KV key constants
│   ├── ICloudObserver.swift                 ← NSUbiquitousKeyValueStore listener
│   ├── ExtensionActivator.swift             ← OSSystemExtensionRequest flow + NEFilterManager config
│   ├── BlocklistService.swift               ← @objc(FoqosBlocklistService) protocol — XPC interface
│   ├── IPCClient.swift                      ← NSXPCConnection client + retry-with-backoff
│   ├── LoginItem.swift                      ← SMAppService.mainApp.register() wrapper
│   ├── EmergencyOverride.swift              ← Keychain wrapper for local 4-digit PIN
│   ├── Assets.xcassets/                     ← AppIcon (Foqos's iOS marketing icon, resized)
│   └── FoqosMac.entitlements                ← KV + App Group + NE content-filter + sysext install
└── FoqosMacFilter/                          ← System Extension (sysext)
    ├── main.swift                           ← NEProvider.startSystemExtensionMode() + dispatchMain()
    ├── FilterDataProvider.swift             ← NEFilterDataProvider subclass, watch-all-flows logic
    ├── BlocklistState.swift                 ← in-memory state cache + alias expansion + shouldBlock
    ├── BlocklistService.swift               ← @objc(FoqosBlocklistService) protocol — identical to container's
    ├── IPCService.swift                     ← NSXPCListener bound to NEMachServiceName
    ├── SNIParser.swift                      ← TLS ClientHello SNI extraction (RFC 6066 §3)
    ├── Info.plist                           ← NEMachServiceName + NEProviderClasses
    └── FoqosMacFilter.entitlements
```

Notes:
- The original Phase B layout had `BridgeState` / `ICloudObserver` inlined in `FoqosMacApp.swift`. Phase C0 (commit 7863e20) split them into separate files once we discovered synchronized file groups (see §6 "Synchronized file groups" below) make this trivial.
- `AppGroupBridge.swift` is gone — deleted in the Phase C5 XPC pivot.
- `BlocklistService.swift` is a duplicated `@objc protocol` in both targets (one declaration per target). The explicit `@objc(FoqosBlocklistService)` runtime name keeps the Objective-C metadata identical across the two binaries so `NSXPCInterface(with:)` introspects matching protocols on each end.

**Synchronized file groups (`PBXFileSystemSynchronizedRootGroup`)**: `FoqosMac.xcodeproj` was created with Xcode 26.x and uses `objectVersion = 77`, which gives each target a synchronized root group. Any Swift file dropped into the target's source directory (e.g. `FoqosMac/FoqosMac/`) is auto-included in the build — **no `project.pbxproj` edit required**. This applies to the container target today and (when Xcode keeps the same default for new targets) will apply to `FoqosMacFilter` once it's added. Adding a new *target* still requires Xcode's GUI; adding new *files* inside an existing target does not. This contrasts with the iOS Foqos project (§5), which uses the traditional file-reference pattern — that's why the iOS bridge was inlined into `Shared.swift`.

### Container app entitlements (current)

- `com.apple.developer.ubiquity-kvstore-identifier` = `$(TeamIdentifierPrefix)com.usetessera.mybrick` (same as iOS — **must NOT default to `$(CFBundleIdentifier)`**, that creates a per-bundle namespace which iOS can't reach)
- `com.apple.security.app-sandbox` = `true`
- `com.apple.security.application-groups` = `[group.com.usetessera.mybrick]`
- `com.apple.developer.networking.networkextension` = `[content-filter-provider]` (legacy variant for Apple Development cert; switch to `content-filter-provider-systemextension` only when moving to Developer ID for distribution)
- `com.apple.developer.system-extension.install` = `true`

### Extension entitlements (current)

- `com.apple.security.app-sandbox` = `true`
- `com.apple.security.application-groups` = `[group.com.usetessera.mybrick]`
- `com.apple.developer.networking.networkextension` = `[content-filter-provider]` (matches container — must be the legacy variant for dev signing)

⚠️ **Critical**: when adding the iCloud capability via Xcode's `+ Capability` dialog, the search for "iCloud" returns BOTH `iCloud` and `iCloud Extended Share Access`. Only the first is wanted. The second is a separate macOS Tahoe capability for in-process app sharing — adds noise + can interfere with provisioning. If accidentally added, click the trash icon on its capability row to remove.

### NEFilterDataProvider behavior on macOS

- System Extension model (NOT app extension) — runs as a privileged service (UID 0, root) after user approval, sandboxed under `~root`.
- "supervised device only" docs apply to iOS, NOT macOS.
- Per-flow callbacks: `handleNewFlow(_:)` decides initially; `handleOutboundData(from:...)` re-inspects bytes if requested.
- New-flow verdicts: `.allow()` (detach, irrevocable — no retroactive kill API), `.drop()` (close at TCP layer), `.filterDataVerdict(filterOutbound: true, peekOutboundBytes: N)` (deliver first N bytes to handleOutboundData), `.pause()` (hold flow until `resumeFlow(_:with:)`).
- Data verdicts: `.allow()` (detach), `.drop()`, `.pauseVerdict()`, `NEFilterDataVerdict(passBytes: P, peekBytes: K)` (release P bytes through, deliver next K to handleOutboundData).

### The current matching pipeline

`FilterDataProvider` runs the full pipeline below for every TCP flow. The `.name` path almost never fires on Tahoe (kernel pre-resolves DNS); SNI inspection from `handleOutboundData` is where actual blocking happens.

```swift
override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    guard let socketFlow = flow as? NEFilterSocketFlow,
          let endpoint = socketFlow.remoteFlowEndpoint
    else { return .allow() }

    // QUIC blackhole — drop UDP/443 to force HTTP/3 → TCP+TLS fallback
    if socketFlow.socketProtocol == Int32(IPPROTO_UDP),
       case .hostPort(_, let port) = endpoint, port.rawValue == 443 {
        return .drop()
    }

    guard case .hostPort(let host, _) = endpoint else { return .allow() }

    switch host {
    case .name(let name, _):                                         // rare on Tahoe
        return BlocklistState.shared.shouldBlock(host: name.lowercased()) ? .drop() : .allow()
    case .ipv4, .ipv6:                                               // ~100 % of real flows
        return .filterDataVerdict(filterOutbound: true,
                                  peekOutboundBytes: 4096)           // peek ClientHello
    @unknown default:
        return .allow()
    }
}

override func handleOutboundData(...) -> NEFilterDataVerdict {
    let flowID = flow.identifier

    // Continuing inspection on a previously-watched flow.
    if let sni = cachedSNI(for: flowID) {
        if BlocklistState.shared.shouldBlock(host: sni) {
            forgetFlow(flowID)
            return .drop()                                            // retroactive kill
        }
        return NEFilterDataVerdict(passBytes: readBytes.count,
                                   peekBytes: Int.max)                // keep inspecting
    }

    // First-time inspection — extract SNI from ClientHello.
    guard let sni = SNIParser.extractSNI(from: readBytes) else {
        return .allow()                                               // fail open (TLS resumption / ECH / non-TLS)
    }
    if BlocklistState.shared.shouldBlock(host: sni) { return .drop() }

    rememberFlow(flowID, sni: sni)                                    // start watching
    return NEFilterDataVerdict(passBytes: readBytes.count,
                               peekBytes: Int.max)
}
```

Why the watch-everything pattern after SNI extraction: see §3 "Filter behavior on state transitions."

Why `peekBytes = Int.max`: see §3 same section. Apple's documented pattern; system delivers per-TCP-segment, so HTTP/2 control bursts wake us per request rather than buffering.

Why no separate FilterControlProvider: not needed for our use case. FilterControlProvider is for separating slow rule-update logic from the hot data path; we get rule updates via XPC into the data provider directly, and rule changes are rare enough that the data path doesn't need protection.

### Apple Developer portal setup (done; reference for fresh team setup)

The dev account currently has all of these in place. Reproducing on a fresh team requires:
1. App ID for `com.usetessera.mybrick.FoqosMac` (container).
2. App ID for `com.usetessera.mybrick.FoqosMac.FoqosMacFilter` (extension — note the parent-bundle prefix; sysextd requires this hierarchy).
3. Network Extensions capability enabled on both (auto-granted for personal/team accounts; commercial use may need an email to networkextension@apple.com).
4. iCloud KV capability enabled on container with identifier `$(TeamIdentifierPrefix)com.usetessera.mybrick`.
5. App Group `group.com.usetessera.mybrick` shared with both targets.
6. Provisioning profiles regenerated. Xcode's "automatic signing" handles most of this once entitlements are configured.

### First-time install UX (current behavior)

1. User builds locally OR receives a notarized .dmg (Phase F not yet shipped).
2. Drag `FoqosMac.app` to `/Applications`.
3. First launch: menu bar icon appears (no Dock icon — `LSUIElement = YES`); `LoginItem.ensureRegistered()` registers for at-login launch on first run.
4. `BridgeState.init()` immediately submits an `OSSystemExtensionRequest.activationRequest(...)` (no UI button required).
5. macOS shows "System Extension Blocked" notification.
6. User opens System Settings → Privacy & Security → unlocks → clicks Allow next to FoqosMacFilter.
7. Network filter prompt: "Allow FoqosMac to filter network content?" → Allow.
8. Filter active. Dropdown shows `Filter: active` caption + current iCloud-synced state.
9. Optional: user opens dropdown → "Set emergency PIN" → enters 4 digits → stored in Keychain for local-only override.

### Emergency override (Phase E3, done)

- 4-digit PIN set on demand from the dropdown UI (`ContentView.Mode.settingPIN`).
- Stored in macOS Keychain via `EmergencyOverride.swift` (`kSecClassGenericPassword`, service `com.usetessera.mybrick.emergency`, `kSecAttrAccessibleWhenUnlocked`). Constant-time PIN compare.
- **Local-only** — never written to iCloud. Engaging the override forces `BridgeState.publishedBlocked = false` in `publishEffectiveState()`, so the filter's `BlocklistState.snapshot.isBlocked` becomes `false` even though the iOS-side iCloud snapshot still says `true`.
- **Auto-lifts** on the next material iCloud transition (any of `isBlocked` / `isBreakActive` / `isPauseActive` / `domains` / `activeProfileId` differs from the snapshot captured at engage time). User can also manually lift via "End override now" button.
- **Recovery if PIN forgotten**: `security delete-generic-password -s 'com.usetessera.mybrick.emergency'` from a terminal.
- Menu bar icon: `lock.slash` (vs `lock.fill` blocked / `lock.open` not blocking) when override is active.

### Login at startup (Phase E1, done)

- `FoqosMac/LoginItem.swift` calls `SMAppService.mainApp.register()` from `FoqosMacApp.init()`.
- Idempotent — early-outs on `.enabled` (already registered) and on `.requiresApproval` (user disabled it in System Settings; we respect that).
- User manages the toggle in System Settings → General → Login Items, where it appears as "FoqosMac".
- Modern API (macOS Ventura+); no LaunchAgent plist or external service needed.

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
- 50-entry profile limit (apps + domains combined); we lean on Mac-side alias expansion (§3) to cover service families like YouTube/Instagram without burning multiple slots.
- `NSUbiquitousKeyValueStore` sync: **~1–2 s typical** for a remote write between iPhone and Mac (verified empirically Phase B). Apple docs say 10-20s, but that's worst-case under load. 1 MB total cap (we use ~5 KB).

### macOS NetworkExtension API facts (verified empirically)

- `NEFilterDataProvider` runs as a System Extension on macOS, NOT an app extension. Runs as **root (UID 0)** under its own per-root sandbox container at `/var/root/Library/Containers/<bundle-id>/`.
- "Supervised device only" docs apply to iOS, NOT macOS.
- **All TCP flows on Tahoe surface as `.ipv4` / `.ipv6` in `NEFilterSocketFlow.remoteFlowEndpoint`**, regardless of client (Safari, Chrome, Firefox, curl, NSURLSession). Kernel resolves DNS before flows reach the filter. The `.name` case in `handleNewFlow` essentially never fires. Hostname-based blocking goes through `handleOutboundData` SNI inspection.
- `NEFilterDataProvider.flow.url` is `nil` for non-WebKit browsers — Chrome flows have no URL info.
- **No retroactive kill API.** Once `handleNewFlow` or `handleOutboundData` returns `.allow()`, the flow detaches from the filter forever. `applySettings`, `handleRulesChanged`, `notifyRulesChanged`, `applyNewFilterRules`, and `resumeFlow` all only affect new or paused flows. Verified via `NEFilterDataProvider.h` and Apple DTS forum thread 735504. Workaround: keep flows under continuing data inspection via `NEFilterDataVerdict(passBytes: N, peekBytes: K)` from `handleOutboundData`. `peekBytes = Int.max` is the documented pattern (Apple forums) — system delivers in natural-sized TCP-segment chunks (~1-1.5 KB).
- **App Group UserDefaults does not work for sysext↔container IPC.** The sysext (root, `~root` sandbox) and container (user 501, `~user` sandbox) resolve `UserDefaults(suiteName:)` to physically separate plists. Apple DTS (Quinn the Eskimo, threads 133543 + 763433) recommends NSXPCConnection instead. We use that.
- `NEMachServiceName` MUST be prefixed with one of the App Groups in `com.apple.security.application-groups`. Sysextd's category-specific validator rejects mismatches with `NetworkExtensionErrorDomain Code=6`.
- Apple Development cert provisioning profiles authorize `content-filter-provider` (legacy) but NOT `content-filter-provider-systemextension`. The latter is gated to Developer ID signing (distribution path).
- `NEFilterDataVerdict.drop()` on a TCP flow PAUSES the flow indefinitely (per Apple DTS) rather than hard-closing it. Browsers see "no response" / connection timeout. Use `curl -v --max-time 8` for definitive verification (browsers may serve cached pages while connections stall).
- `NEDNSProxyProvider` is bypassed by Chrome's DoH (default on in 2026) and by any DoH/DoT system DNS.
- `EndpointSecurity` entitlement is gated to security vendors — not available to solo dev.
- iCloud Private Relay routes Safari traffic invisibly to local content filters; **not relevant since user uses Chrome**.
- Apple's `SimpleFirewall` (WWDC19) is the canonical NEFilterDataProvider sample. Uses NSXPCConnection over `NEMachServiceName` for container↔filter IPC — same pattern we use.
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

**Done (Phase E — polish + filter robustness)** (commits `a8a406c`, `24239ce`, `920a0bb`, `2b55e1b`, plus the small comment fix in this commit):
1. ✅ E1 — SMAppService login-at-startup. `FoqosMac/LoginItem.swift`. Idempotent `SMAppService.mainApp.register()` from `FoqosMacApp.init`. Respects user disabling in System Settings (early-out on `.requiresApproval`).
2. ✅ E5 — Custom AppIcon. Foqos's iOS marketing icon resized to all 10 macOS slots via `scripts/build-app-icons.sh` (sips). Generated PNGs committed to `FoqosMac/FoqosMac/Assets.xcassets/AppIcon.appiconset/`. Re-run the script after pulling fresh upstream Foqos assets.
3. ✅ E2 — Menu bar icon. Kept SF Symbols for theme-awareness + macOS convention. Three-state: `lock.fill` (blocked), `lock.open` (not blocking), `lock.slash` (emergency override active). Note: `BridgeState.isCurrentlyBlocking` factors in break/pause too (so the icon shows `lock.open` during a break, even though iCloud says `isBlocked=true`); the filter still receives the raw flags via `publishedBlocked` so it can do its own break/pause logic.
4. ✅ `LSUIElement = YES` already done in C0.
5. ✅ E3 — Emergency override (4-digit PIN in Keychain). `FoqosMac/EmergencyOverride.swift`. Stored under service `com.usetessera.mybrick.emergency`, `kSecAttrAccessibleWhenUnlocked`. Constant-time PIN compare. UI integrated into ContentView mode state machine (`.main` ↔ `.settingPIN` ↔ `.enteringPIN`). Engaging override forces `BridgeState.publishedBlocked = false` in `publishEffectiveState()`; auto-lifts on the next material iCloud transition (any of `isBlocked` / break / pause / `domains` / `activeProfileId` changes vs. the snapshot taken at engage time). Local-only — never written to iCloud per §6.
6. ✅ ContentView UX overhaul — single-line top status combines block / break / pause / override; dropped `isBlocked` / `isBreakActive` / `isPauseActive` / `Profile` rows; domain-count line replaces the (truncated) domain list; removed `Force sync` (kept `Quit`); `Synced X:XX` footer.
7. ✅ Filter behavior on state transitions — see §3 "Filter behavior on state transitions." `FilterDataProvider` now keeps every TLS flow under continuing inspection (`peekBytes = Int.max`) instead of returning `.allow()` and detaching. Existing TCP connections die on the next outbound chunk after a state change (break end, rebrick, blocklist mutation). Necessary because `NEFilterDataProvider` has no retroactive kill API for `.allow()`d flows; verified via Apple headers + DTS forum thread 735504. Cost: 0% idle, ~0.05% on a 5 Mbps stream, ~0.25% on 25 Mbps 4K — below the noise floor on M2 Air.
8. ✅ Alias expansion in `BlocklistState.domainAliases` — see §3 "Alias expansion." Profile entries `youtube.com` and `instagram.com` expand to their full service-domain set so the user enters one canonical SLD per service and the Mac filter handles per-service coverage. Conservative inclusion criteria; `ggpht.com` / `googleapis.com` / `fbcdn.net` deliberately excluded (over-block adjacent services).

**Pending (Phase F: distribution)**:
- TestFlight for iPhone (Foqos fork) — friend installs via TestFlight invite, no paid Dev account on their side. Builds expire after 90 days; you re-upload periodically.
- Developer ID + notarize for Mac — switch Release signing from Apple Development → Developer ID Application; switch NE entitlement from `content-filter-provider` → `content-filter-provider-systemextension` for Release builds; build → `xcrun notarytool submit --wait` → `xcrun stapler staple` → ship .dmg.
- Self-deploy script `scripts/deploy-mac.sh` — wraps `xcodebuild` + `ditto /Applications` + relaunch.
- Parameterized share recipe — extend `apply-mybrick-overrides.sh` to take `TEAM_ID` + `BUNDLE_PREFIX` so a friend with their own paid Dev account could fork-and-build (alternative path to TestFlight).
- Documentation: §18 "Distribution & sharing."

### Cross-cutting learnings (preserve for future sessions)

- **macOS Tahoe 26.3 surfaces ALL flows as IP, not hostname.** Every TCP flow shows `.ipv4` / `.ipv6` on `NEFilterSocketFlow.remoteFlowEndpoint`, never `.name` — regardless of client (Safari, Chrome, Firefox, curl, NSURLSession). Kernel resolves DNS before flows reach the filter. Hostname matching from `handleNewFlow` essentially never fires. **All blocking goes through `handleOutboundData` SNI inspection.** Phase D became the actual functional path, not a Chrome-only optimization.
- **NEFilterDataProvider has no retroactive kill API for `.allow()`d flows.** Verified via `NEFilterDataProvider.h` and Apple DTS forum thread 735504 (*"once I return an allow/deny verdict for the flow … do I no longer see that flow's traffic in my content filter? — Correct."*). `applySettings`, `handleRulesChanged`, `notifyRulesChanged`, `applyNewFilterRules`, `resumeFlow` all only affect new or paused flows. Workaround: never return `.allow()` from `handleOutboundData` for TLS flows; instead return `NEFilterDataVerdict(passBytes: N, peekBytes: Int.max)` to keep the flow under continuing inspection. State changes propagate on the next outbound chunk.
- **`peekBytes = Int.max` is the right choice for continuing TLS inspection.** Apple's forum-documented pattern. System delivers in natural-sized TCP-segment chunks (~1-1.5 KB) rather than buffering up to a fixed threshold. Matters for HTTP/2 control plane: with `peekBytes = 64 KB`, a browsing session can fire dozens of small request headers before our callback wakes up — state-change reaction is effectively never. With `Int.max`, every TCP segment fires a callback and reaction is bounded by user activity.
- **Service-domain alias expansion is needed because canonical SLDs don't suffix-match service CDNs.** `youtube.com` only matches `*.youtube.com` — NOT `googlevideo.com` (where YouTube actually streams its videos). Without expansion, blocking `youtube.com` lets video chunks load freely on existing tabs. Expansion happens in `BlocklistState.domainAliases` at update time. Conservative criteria: an alias domain is included only if exclusively (or near-exclusively) used by the named service. `ggpht.com` / `googleapis.com` / `fbcdn.net` deliberately excluded (over-block adjacent services). To extend: add a new mapping; no iOS-profile rebuild needed.
- **Apple Development cert profiles authorize `content-filter-provider` (legacy), NOT `content-filter-provider-systemextension`.** The `-systemextension` suffix is gated to Developer ID signing. Xcode's "+ Capability → Network Extensions → Content Filter" UI also writes the legacy value. To ship eventually we'd need Developer ID. For dev: use legacy.
- **`NEMachServiceName` MUST be prefixed with one of the App Groups** in `com.apple.security.application-groups`. Sysextd's category-specific validator returns `NetworkExtensionErrorDomain Code=6` if not. Our App Group is `group.com.usetessera.mybrick` (literal `group.` prefix, not team-prefixed) so the Mach service is `group.com.usetessera.mybrick.FoqosMacFilter`. Apple's SimpleFirewall sample team-prefixes BOTH (App Group is `$(TeamIdentifierPrefix)<bundle-id>`); we can't follow that pattern because iOS Foqos uses the `group.` form.
- **Darwin notification names from sandboxed processes MUST be prefixed with the App Group.** Was `com.usetessera.mybrick.state.changed`, fixed to `group.com.usetessera.mybrick.state.changed`. Sandbox silently drops mismatched notifications. (Historical — Darwin notifications are no longer used since the C5 XPC pivot, but the rule is still relevant if anyone ever reaches for them.)
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

- Apple's `SimpleFirewall` — minimal NEFilterDataProvider sample. WWDC 2019 session 714. Uses NSXPCConnection over `NEMachServiceName` for container↔filter IPC — same pattern as us. Search "SimpleFirewall site:developer.apple.com".
- Apple Developer Forums threads (Quinn the Eskimo) for sysext IPC + filter behavior:
  - 763433 — "App groups aren't as useful in a sysex" (canonical UID-split quote).
  - 133543 — "use XPC instead of App Group containers" recommendation.
  - 706503 — `/var/root/Library/Containers` + sysext sandbox.
  - 735504 — "once I return allow/deny … do I no longer see traffic? Correct" (no-retroactive-kill API confirmation).
  - 750912 — "Data storage for Network Extension" — `notifyRulesChanged()` / `handleRulesChanged()` mechanism (not used here; only affects new flows).
  - 721701 — "App Groups: macOS vs iOS: Fight!" (iOS-style `group.X` vs macOS-style `<TeamID>.X` naming; both supported on macOS as of Feb 2025).
- LuLu by Patrick Wardle — production NETransparentProxyProvider on macOS. https://github.com/objective-see/LuLu. Useful: entitlements plist, System Extension activation flow. NOT useful for our specific patterns: LuLu doesn't do SNI inspection (it accepts the IP-only limitation), and doesn't keep flows under continuing inspection for retroactive kill.
- For TLS ClientHello SNI parsing in Swift: `FoqosMacFilter/SNIParser.swift` is the local reference (~120 LOC, bounds-checked Cursor pattern, golden-vector test in `SNIParserSanityCheck`). The TLS ClientHello structure is in RFC 8446 §4.1.2 (TLS 1.3) and RFC 5246 §7.4.1.2 (TLS 1.2); SNI extension is RFC 6066 §3.

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

### Verifying the full pipeline

**Best path: `scripts/c5-verify.sh`** — see §16. It builds, deploys to `/Applications`, asserts the XPC handshake, runs curl tests against the iPhone-bricked-domain (when `TEST_BLOCKED_DOMAIN` is set), and dumps a verdict. 6/6 baseline; 7/7 with the real-iPhone test.

**Live diagnostic stream** during interactive testing:

```bash
log stream --predicate "subsystem == 'com.usetessera.mybrick'" --info --debug --style compact
```

Categories worth grepping:
- `IPCClient`, `IPCService` — XPC handshake events (publish, retry, listener accept).
- `BlocklistState` — `Updated:` lines when a fresh snapshot arrives. The `effectiveDomains=N` part includes alias expansion.
- `FilterDataProvider` — `SNI watch <host>` (kept under inspection), `SNI DROP <host>` (first-flow drop), `SNI DROP <host> [retroactive — state changed, bytes=N]` (continuing-inspection drop), `flow DROP udp/443` (QUIC blackhole), `SNI nil` (couldn't parse — usually mDNS or TLS resumption).
- `ExtensionActivator` — startup activation lifecycle (`Replacing existing extension`, `Filter active and enabled`).
- `LoginItem` — at-launch login-item registration.
- `EmergencyOverride` — PIN-set / PIN-verify events.

⚠️ **Always include `--info --debug`** in `log show` / `log stream` predicates. `Logger.info` messages are filtered out by default; without these flags it'll look like the filter isn't running when it just isn't logging at the visible level.

⚠️ **Console.app is NOT a reliable verification path.** Console.app on macOS Tahoe filters out `os_log` Info messages from physical iPhones inconsistently even with "Include Info Messages" enabled. iOS debugging story works through Xcode's debug area when the debugger is attached.

---

---

## 16. Dev workflow scripts (Mac)

All under `scripts/`. Run from the user's terminal (Claude's sandbox blocks xcodebuild, log show, /Applications writes).

### `scripts/dev-iterate.sh`
One-shot dev iteration loop. Bumps `CURRENT_PROJECT_VERSION`, builds via xcodebuild, copies fresh `.app` to `/Applications`, kills old processes, launches, then `exec /usr/bin/log stream` to tail extension logs (Ctrl-C to exit). Reverts pbxproj at end so working tree stays clean.

Use when: making code changes during active dev, want to see live logs while testing.

### `scripts/c5-verify.sh`
End-to-end verification with bump→build→deploy→XPC-handshake-check→curl-tests→capture-logs→verdict. Bumps `CURRENT_PROJECT_VERSION` to `date +%s` (always unique, forces OS replace). Reverts pbxproj at end so working tree stays clean. Asserts:
1. Filter listener started (XPC `IPCService` log).
2. Filter accepted client connection.
3. Filter received at least one snapshot from the container.
4. Container published at least one snapshot (XPC `IPCClient` log).
5. `BlocklistState.update` happened (snapshot reached the matching engine).
6. `curl https://www.apple.com` → 200 (filter not blackholing).
7. (Optional) `curl https://$TEST_BLOCKED_DOMAIN` → connection failure when env var is set and the iPhone is bricked with that domain in its profile.

Output: `scripts/c5-verify.out` with a clear PASS/FAIL verdict and full diagnostic logs (FilterDataProvider, BlocklistState, IPCService, IPCClient, ExtensionActivator categories).

Currently passes 6/6 with no env var, 7/7 with `TEST_BLOCKED_DOMAIN=instagram.com` and the iPhone bricked.

### `scripts/c5-lsof-check.sh`
One-shot diagnostic that captures verbatim evidence of the sysext UID-split (filter PID's UID + cwd + open files; user-side vs root-side App Group container paths). Used to ground-truth the Phase C5 BLOCKER hypothesis before pivoting to XPC. Output goes to `scripts/c5-lsof-check.out`. Useful as historical evidence in commit messages; rarely needs to be re-run unless someone questions the diagnosis.

### `scripts/build-app-icons.sh`
Resizes Foqos's iOS marketing AppIcon (1024×1024) into all 10 macOS slot sizes via `sips` and writes them to `FoqosMac/FoqosMac/Assets.xcassets/AppIcon.appiconset/`. Generated PNGs are committed; re-run after pulling fresh upstream Foqos icons.

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
  - §3 (architecture — high-level flow, hostname problem, IPC, filter
    behavior on state transitions, alias expansion)
  - §6 (Mac app architecture — current target layout post-Phase E)
  - §11 (execution state — every phase commit-by-commit)
  - §11 cross-cutting learnings — failure modes already discovered
  - §14 (reference architectures — Apple DTS forum threads to consult)
  - §16 (dev workflow scripts)

STEP 2: confirm state via git log.
  cd ~/projects/FoqosUp && git log --oneline -25

  All phases A → E complete. Most recent commits should be the Phase E
  filter-robustness work (peekBytes=Int.max, watch-all-flows, alias
  expansion). Phase F (distribution) is the next major chunk.

STEP 3: where things stand.

WHAT WORKS (all verified end-to-end, c5-verify.sh 6/6 baseline + 7/7
with TEST_BLOCKED_DOMAIN=instagram.com):
  - iCloud bridge iOS↔Mac (Phase A+B): brick iPhone → Mac dropdown
    shows isBlocked=true, domains=..., within ~1-2 s.
  - System Extension install + activation (Phase C0-C4).
  - SNI inspection + drop (Phase D): hostname-based blocking via TLS
    ClientHello inspection. QUIC blackhole forces TCP+TLS fallback for
    HTTP/3.
  - Container↔filter IPC via NSXPCConnection (Phase C5): container's
    BridgeState.refresh() pushes JSON-encoded BlocklistSnapshot through
    IPCClient → filter's IPCService → BlocklistState.update(). Replaced
    the earlier App Group UserDefaults + Darwin design which is
    unworkable due to the sysext UID split. See §11 "Phase C5 root cause"
    for verbatim lsof + DTS evidence.
  - State-change reactivity (Phase E filter robustness): existing TLS
    flows die on the next outbound chunk after a state change (break
    end, rebrick, blocklist mutation). Achieved by keeping every TLS
    flow under continuing data inspection (peekBytes=Int.max) instead
    of returning .allow() and detaching. NEFilterDataProvider has no
    retroactive kill API for already-allowed flows; this is the only
    workaround.
  - Alias expansion (Phase E): user enters `youtube.com` in iOS
    profile, Mac filter expands to {youtube.com, googlevideo.com,
    ytimg.com, youtu.be, youtube-nocookie.com}. Same for instagram.com
    → {instagram.com, cdninstagram.com}.
  - Login at startup (Phase E1): SMAppService.mainApp.register() from
    FoqosMacApp.init().
  - Emergency PIN override (Phase E3): local Keychain PIN; engaging
    forces filter to isBlocked=false; auto-lifts on next iCloud
    transition.
  - Custom AppIcon: Foqos's iOS marketing icon resized to all 10 macOS
    slot sizes via scripts/build-app-icons.sh.

WHAT'S NEXT (Phase F — distribution, the only major chunk left):
  - TestFlight for iPhone (Foqos fork): friends install via TestFlight
    invite, no paid Dev account on their side, builds expire at 90 days.
  - Developer ID + notarize for Mac: switch Release signing from Apple
    Development → Developer ID Application; flip NE entitlement to
    `content-filter-provider-systemextension` for Release; build →
    notarytool submit → stapler staple → ship .dmg. Friends drag to
    /Applications, approve sysext once. iCloud KV namespace is your
    team-prefixed value; each friend signs in with their own iCloud,
    so per-friend state is isolated.
  - scripts/deploy-mac.sh: thin wrapper for self-deploy (xcodebuild →
    ditto /Applications → relaunch).
  - Parameterized share recipe: extend apply-mybrick-overrides.sh to
    take TEAM_ID + BUNDLE_PREFIX env vars for a friend who has their
    own paid Dev account and wants to fork-and-build instead of
    accepting a TestFlight build.
  - CLAUDE.md §18: distribution & sharing process docs.

OPERATIONAL RULES:
  - Senior-SWE rigor bar: clean modular code, ground-truth research
    before pivoting, document trade-offs in commit messages, verbatim
    diagnostic evidence in commit bodies (the C5 commit shows the
    pattern).
  - Sandbox blocks xcodebuild, log show, /Applications writes, and
    sudo from Claude's environment. User runs scripts; Claude reads
    .out files. Don't ask the user to do things Claude can do itself.
  - Be terse. Test before claiming. Trust git log.
  - SIP is ON, dev-mode is OFF. /Applications deployment + Apple
    Development cert is the dev path. `.replace` verdict in
    actionForReplacingExtension handles cdhash-different rebuilds; old
    extension versions pile up as "terminated waiting to uninstall on
    reboot" until reboot.
  - When in doubt about Apple APIs, prefer Apple Developer Forums
    (Quinn the Eskimo's threads — see §14) over web search.
  - When asked "would you 100% approve this?", critique honestly,
    push back on premature optimization, distinguish must-have from
    nice-to-have.
```

---

**Last fork sync**: Foqos 1.32.4 (commit `5ac998f`, 2026)
**Document version**: 2026-05-01 — Phases A through E all complete (login-at-startup, AppIcon, dropdown UX, emergency PIN, filter state-transition reactivity, service-domain alias expansion). c5-verify.sh 6/6 baseline + 7/7 with real iPhone state. Phase F (distribution: TestFlight + notarize + deploy script + parameterized share recipe) is the only remaining major work item.
