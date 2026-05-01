import Combine
import Foundation
import OSLog

@MainActor
final class BridgeState: ObservableObject {
  @Published var isBlocked: Bool = false
  @Published var isBreakActive: Bool = false
  @Published var isPauseActive: Bool = false
  @Published var activeProfileId: String?
  @Published var domains: [String] = []
  @Published var lastUpdated: Date?
  @Published var filterStatus: FilterStatus = .unknown

  /// Local emergency override state. When `emergencyOverrideActive == true`,
  /// the snapshot pushed to the filter is forced to `isBlocked = false`
  /// regardless of iCloud state. Auto-lifts on the next material iCloud
  /// transition (so when the iPhone unbricks/re-bricks, the override goes
  /// away and the filter resumes following iCloud). Per CLAUDE.md §6 this
  /// state is local only — never written to iCloud.
  @Published var emergencyOverrideActive: Bool = false
  @Published var emergencyPINSet: Bool = EmergencyOverride.isPINSet

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "BridgeState")
  private let observer = ICloudObserver()
  private lazy var activator = ExtensionActivator(state: self)

  /// iCloud snapshot at the moment the override was engaged. Used to detect
  /// material transitions on subsequent refreshes so the override auto-lifts.
  private var iCloudSnapshotAtOverride: ICloudSnapshot?

  init() {
    observer.onChange = { [weak self] in
      Task { @MainActor in self?.refresh() }
    }
    refresh()
    observer.start()
    activator.activateIfNeeded()
  }

  var menuBarSymbol: String {
    if emergencyOverrideActive { return "lock.slash" }
    if isCurrentlyBlocking { return "lock.fill" }
    return "lock.open"
  }

  var summary: String {
    if emergencyOverrideActive { return "Emergency unblocked" }
    if !isBlocked { return "Not blocking" }
    if isBreakActive { return "On break" }
    if isPauseActive { return "Paused" }
    return "Blocked"
  }

  /// True iff the filter is actively dropping flows right now. Combines all
  /// suppression sources: raw iCloud `isBlocked`, plus break, pause, and the
  /// local emergency override. Drives the menu-bar lock icon and the header
  /// status. Note: this is UI-only; what we actually send to the filter is
  /// `publishedBlocked`, which omits break/pause so the filter side reasons
  /// about those locally (matches `BlocklistState.shouldBlock`).
  var isCurrentlyBlocking: Bool {
    isBlocked && !emergencyOverrideActive && !isBreakActive && !isPauseActive
  }

  /// What we publish to the filter as `isBlocked`. Diverges from raw iCloud
  /// only when the local emergency override is engaged. Break/pause are
  /// passed through as their own flags so the filter's `BlocklistState` does
  /// the actual suspension logic.
  private var publishedBlocked: Bool {
    isBlocked && !emergencyOverrideActive
  }

  func refresh() {
    let store = NSUbiquitousKeyValueStore.default
    isBlocked = store.bool(forKey: BridgeKey.isBlocked)
    isBreakActive = store.bool(forKey: BridgeKey.isBreakActive)
    isPauseActive = store.bool(forKey: BridgeKey.isPauseActive)
    activeProfileId = store.string(forKey: BridgeKey.activeProfileId)
    if let data = store.data(forKey: BridgeKey.activeBlocklistDomains),
      let arr = try? JSONDecoder().decode([String].self, from: data)
    {
      domains = arr
    } else {
      domains = []
    }
    let ts = store.double(forKey: BridgeKey.lastUpdated)
    lastUpdated = ts > 0 ? Date(timeIntervalSince1970: ts) : nil

    // Auto-lift the emergency override on any material iCloud transition.
    if emergencyOverrideActive,
      let pre = iCloudSnapshotAtOverride,
      pre.materiallyDiffersFromCurrent(in: self)
    {
      log.info("Emergency override auto-lifted (iCloud state transitioned)")
      emergencyOverrideActive = false
      iCloudSnapshotAtOverride = nil
    }

    publishEffectiveState()
  }

  func forceSync() {
    NSUbiquitousKeyValueStore.default.synchronize()
    refresh()
  }

  // MARK: - Emergency override

  /// Set (or replace) the local emergency PIN. Caller is responsible for
  /// validating the format (4 numeric digits) before calling.
  func setEmergencyPIN(_ pin: String) throws {
    try EmergencyOverride.setPIN(pin)
    emergencyPINSet = true
  }

  /// Engage the override iff `pin` matches the stored PIN. Returns `true`
  /// on success.
  func engageEmergencyOverride(pin: String) -> Bool {
    guard EmergencyOverride.verifyPIN(pin) else { return false }
    iCloudSnapshotAtOverride = ICloudSnapshot(from: self)
    emergencyOverrideActive = true
    log.info("Emergency override ENGAGED")
    publishEffectiveState()
    return true
  }

  /// Manual lift, e.g. user clicks "End override" in the dropdown. (Auto-lift
  /// on iCloud transition is the more common path.)
  func disengageEmergencyOverride() {
    guard emergencyOverrideActive else { return }
    emergencyOverrideActive = false
    iCloudSnapshotAtOverride = nil
    log.info("Emergency override LIFTED (manual)")
    publishEffectiveState()
  }

  // MARK: - Internals

  private func publishEffectiveState() {
    IPCClient.shared.publish(
      isBlocked: publishedBlocked,
      isBreakActive: isBreakActive,
      isPauseActive: isPauseActive,
      domains: domains
    )
  }
}

/// Snapshot of the iCloud-derived fields used for override auto-lift detection.
/// We only care about fields whose change indicates "iPhone state moved" —
/// `lastUpdated` is excluded because iCloud bumps it on every write even when
/// no functional field changed.
private struct ICloudSnapshot {
  let isBlocked: Bool
  let isBreakActive: Bool
  let isPauseActive: Bool
  let domains: [String]
  let activeProfileId: String?

  init(from state: BridgeState) {
    self.isBlocked = state.isBlocked
    self.isBreakActive = state.isBreakActive
    self.isPauseActive = state.isPauseActive
    self.domains = state.domains
    self.activeProfileId = state.activeProfileId
  }

  func materiallyDiffersFromCurrent(in state: BridgeState) -> Bool {
    return isBlocked != state.isBlocked
      || isBreakActive != state.isBreakActive
      || isPauseActive != state.isPauseActive
      || domains != state.domains
      || activeProfileId != state.activeProfileId
  }
}
