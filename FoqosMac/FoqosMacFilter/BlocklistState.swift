import Foundation
import OSLog

/// Filter-side mirror of FoqosMac/AppGroupBridge.swift constants. Must stay
/// in lock-step with the container's definition — these are the IPC contract.
enum AppGroupConstants {
  static let suiteName = "group.com.usetessera.mybrick"
  static let blocklistSnapshotKey = "com.usetessera.mybrick.blocklist.v1"
  static let stateChangedDarwinName = "com.usetessera.mybrick.state.changed"
}

/// Filter-side copy of the wire payload. Identical Codable structure to the
/// container's BlocklistSnapshot — they serialize to the same JSON bytes,
/// which is the only thing that has to match. Duplicated because each Xcode
/// target gets only its own synchronized-group source dir; sharing a single
/// .swift file across both targets would require a pbxproj-level membership
/// exception, which isn't worth the complexity for ~20 lines.
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

/// Thread-safe in-memory blocklist used by the FilterDataProvider hot path.
/// Reads are uncontended NSLock acquires (~10ns each); writes happen on
/// Darwin notification (low frequency). FilterDataProvider's handleNewFlow
/// and handleOutboundData are serialized through Apple's per-filter queue
/// (per Apple DTS), so write contention with reads is rare in practice but
/// the lock is here for correctness on the off-chance the Darwin callback
/// runs concurrently with a filter callback.
final class BlocklistState: @unchecked Sendable {
  static let shared = BlocklistState()

  private let log = Logger(subsystem: "com.usetessera.mybrick", category: "BlocklistState")
  private let lock = NSLock()
  private var snapshot: BlocklistSnapshot = .empty

  private init() {}

  /// Returns true iff blocking is currently active AND the host matches one
  /// of the blocklist entries (suffix-matched, so "youtube.com" also blocks
  /// "m.youtube.com" / "studio.youtube.com").
  func shouldBlock(host: String) -> Bool {
    lock.lock()
    let snap = snapshot
    lock.unlock()
    guard snap.isBlocked, !snap.isBreakActive, !snap.isPauseActive else { return false }
    let h = host.lowercased()
    for entry in snap.domains where !entry.isEmpty {
      let e = entry.lowercased()
      if h == e || h.hasSuffix(".\(e)") { return true }
    }
    return false
  }

  /// Read the latest snapshot from App Group UserDefaults and atomically
  /// swap. Called once at filter startup and on every Darwin notification.
  func reloadFromAppGroup() {
    guard let defaults = UserDefaults(suiteName: AppGroupConstants.suiteName) else {
      log.error("App Group UserDefaults nil — entitlement / suite name mismatch?")
      return
    }

    guard let data = defaults.data(forKey: AppGroupConstants.blocklistSnapshotKey) else {
      lock.lock()
      snapshot = .empty
      lock.unlock()
      log.info("No snapshot in App Group; using empty (fail-open).")
      return
    }

    do {
      let new = try JSONDecoder().decode(BlocklistSnapshot.self, from: data)
      lock.lock()
      snapshot = new
      lock.unlock()
      log.info(
        "Reloaded: blocked=\(new.isBlocked, privacy: .public) break=\(new.isBreakActive, privacy: .public) pause=\(new.isPauseActive, privacy: .public) domains=\(new.domains.count, privacy: .public)"
      )
    } catch {
      // Corrupt or schema-incompatible payload — fail open. Log so we notice.
      log.error(
        "Decode snapshot failed: \(error.localizedDescription, privacy: .public). Falling back to empty."
      )
      lock.lock()
      snapshot = .empty
      lock.unlock()
    }
  }
}
