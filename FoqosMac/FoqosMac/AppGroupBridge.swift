import Foundation
import OSLog

/// Constants shared between the container and the filter target. Both files
/// (this one + FoqosMacFilter/BlocklistState.swift) must keep these in lock-
/// step. The App Group + Darwin notification name + key name are the IPC
/// contract. If the schema ever evolves, bump `blocklistSnapshotKey` to v2 so
/// stale-version clients fail closed (decode → nil → empty snapshot).
enum AppGroupConstants {
  static let suiteName = "group.com.usetessera.mybrick"
  static let blocklistSnapshotKey = "com.usetessera.mybrick.blocklist.v1"
  /// Darwin notification name. MUST be prefixed with the App Group identifier;
  /// sandboxed processes can only post/subscribe to Darwin notifications whose
  /// names live under one of their entitled App Groups.
  static let stateChangedDarwinName = "group.com.usetessera.mybrick.state.changed"
}

/// Wire-format payload that crosses container ↔ filter via App Group
/// UserDefaults. JSON-encoded so a future re-implementation of either side
/// in a different toolchain still reads the same bytes. Defined identically
/// in FoqosMacFilter/BlocklistState.swift.
struct BlocklistSnapshot: Codable, Equatable {
  let isBlocked: Bool
  let isBreakActive: Bool
  let isPauseActive: Bool
  let domains: [String]
  let lastUpdated: Double

  static let empty = BlocklistSnapshot(
    isBlocked: false,
    isBreakActive: false,
    isPauseActive: false,
    domains: [],
    lastUpdated: 0
  )
}

/// Container-side singleton that mirrors iCloud-derived state into the App
/// Group and notifies the filter to reload. Lives on the main actor because
/// it's invoked from `BridgeState.refresh()` which is `@MainActor`.
@MainActor
final class AppGroupBridge {
  static let shared = AppGroupBridge()

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "AppGroupBridge")
  private let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName)
  private var lastPosted: BlocklistSnapshot?

  private init() {}

  /// Encode the current state, write to the App Group, post a Darwin notification.
  /// Skips the write+post if no material field changed since the last call —
  /// dedup avoids waking the filter unnecessarily on iCloud chatter that
  /// produces identical refreshes (e.g. lastUpdated bumps with no real change).
  func publish(
    isBlocked: Bool,
    isBreakActive: Bool,
    isPauseActive: Bool,
    domains: [String]
  ) {
    let snap = BlocklistSnapshot(
      isBlocked: isBlocked,
      isBreakActive: isBreakActive,
      isPauseActive: isPauseActive,
      domains: domains,
      lastUpdated: Date().timeIntervalSince1970
    )

    if let prev = lastPosted,
      prev.isBlocked == snap.isBlocked,
      prev.isBreakActive == snap.isBreakActive,
      prev.isPauseActive == snap.isPauseActive,
      prev.domains == snap.domains
    {
      return
    }

    guard let defaults else {
      log.error("App Group UserDefaults nil — entitlement / suite name mismatch?")
      return
    }

    do {
      let data = try JSONEncoder().encode(snap)
      defaults.set(data, forKey: AppGroupConstants.blocklistSnapshotKey)
      // synchronize() is officially deprecated as a no-op on iOS, but on
      // macOS with App Group suites it still flushes to disk synchronously
      // — and we need that durability before posting the Darwin notification,
      // otherwise the filter's reload could read stale bytes.
      defaults.synchronize()

      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(AppGroupConstants.stateChangedDarwinName as CFString),
        nil,
        nil,
        true
      )

      lastPosted = snap
      log.info(
        "Published: blocked=\(snap.isBlocked, privacy: .public) break=\(snap.isBreakActive, privacy: .public) pause=\(snap.isPauseActive, privacy: .public) domains=\(snap.domains.count, privacy: .public)"
      )
    } catch {
      log.error("Encode snapshot failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
